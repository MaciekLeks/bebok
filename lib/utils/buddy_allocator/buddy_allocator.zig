//! Self-allocating Buddy Allocator
//! This is an implementation of a buddy allocator based on the bitmap tree architecture.
//! The allocator uses the same mechanism for two purposes: Allocating memory for the internal BuddyBitmapTree buffer and for client allocations.
//! This means it doesn't require any additional memory beyond the resources initially provided.
const std = @import("std");
const bbtree = @import("bbtree.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.buddy_allocator);
const assert = std.debug.assert;
const t = std.testing;

pub fn BuddyAllocator(comptime max_levels: u8, comptime min_size: usize) type {
    const BBTree = bbtree.BuddyBitmapTree(max_levels, min_size);

    const AllocInfo = struct {
        size_pow2: usize, //allocated memory
        vaddr: usize, //virtual address
    };

    return struct {
        const Self = @This();

        tree: *BBTree = undefined,
        unmanaged_mem_size: usize = undefined,
        max_mem_size_pow2: usize = undefined,
        free_mem_size: usize = undefined,
        mem_vaddr: usize = undefined, //start of the memory to be managed the allocator

        // Initialize the allocator with the given memory by allocating the buffer for the tree and self object in that memory.
        pub fn init(mem: []u8) !*Self {
            assert(mem.len >= BBTree.page_size);
            const mem_max_size_pow2 = std.math.floorPowerOfTwo(usize, mem.len);

            // config on the stack
            var config = try BBTree.Metadata.init(mem_max_size_pow2, BBTree.page_size);

            const self_size = @sizeOf(Self);
            const tree_size = @sizeOf(BBTree);
            const tree_buffer_size = config.len;
            const tree_meta_level_size = config.level_meta.len * @sizeOf(BBTree.LevelMetadata);
            // minimal size is the sum of the size of the self object, the size of the buffer, and the size of the tree
            const min_size_needed = self_size + @alignOf(Self) + tree_buffer_size + @alignOf([]u8)  + tree_size + @alignOf(BBTree) + tree_meta_level_size + @alignOf(BBTree.LevelMetadata); // we added alignments just in caase
            const size_needed = @max(min_size_needed, BBTree.page_size);
            const size_needed_pow2 = try std.math.ceilPowerOfTwo(usize, size_needed);
            //log everuthing from min_sel_size to size_needed_pow2
            log.debug("init:   self_size: 0x{x}  buffer_size: 0x{x}  size_needed: 0x{x}  size_needed: 0x{x}  size_needed_pow2: 0x{x}, frame/page_size: 0x{x}", .{ self_size, tree_buffer_size, min_size_needed, size_needed, size_needed_pow2, BBTree.page_size });

            assert(mem.len >= size_needed_pow2);

            // get vaddr
            const level_meta = config.levelMetaFromSize(size_needed_pow2) catch return error.OutOfMemory;
            const self_index = level_meta.offset;
            const vaddr = @intFromPtr(mem.ptr);
            const start_vaddr = absVaddrFromIndex(vaddr, level_meta.offset); //we do not have self yet
            const self_mem: []u8 = @as([*]u8, @ptrFromInt(start_vaddr))[0..size_needed_pow2];

            var fba = std.heap.FixedBufferAllocator.init(self_mem);
            const fba_allocator = fba.allocator();

            // move config on the heap, and create the tree
            const tree = try BBTree.init(fba_allocator, try config.dupe(fba_allocator), try fba_allocator.alloc(u8, tree_buffer_size));

            const self = try fba_allocator.create(Self);
            self.* = .{
                .unmanaged_mem_size = mem.len - mem_max_size_pow2,
                .max_mem_size_pow2 = mem_max_size_pow2,
                .free_mem_size = mem_max_size_pow2,
                .tree = tree,
                .mem_vaddr = vaddr,
            };


            self.tree.setChunk(self_index);
            self.free_mem_size -= level_meta.size;

            return self;
        }

        inline fn absVaddrFromIndex(vaddr: usize, idx: usize) usize {
            return vaddr + BBTree.page_size * idx;
        }

        inline fn vaddrFromIndex(self: Self, idx: usize) usize {
            return absVaddrFromIndex(self.mem_vaddr, idx);
        }

        inline fn indexFromVaddr(self: *Self, vaddr: usize) usize {
            assert(vaddr >= self.mem_vaddr);
            return (vaddr - self.mem_vaddr) / BBTree.page_size;
        }

        pub inline fn minAllocSize(size: usize) !usize {
            return try std.math.ceilPowerOfTwo(usize, @max(BBTree.page_size, size)); //e.g. 1->4, 16 -> 16, but 17,18,... -> 32
        }

        pub fn allocInner(self: *Self, size_pow2: usize) !AllocInfo {
            const idx = (self.tree.freeIndexFromSize(size_pow2)) catch return error.OutOfMemory;
            log.debug("allocInner(): idx: {d}", .{idx});

            self.tree.setChunk(idx);

            //self.tree.dump();

            self.free_mem_size -= size_pow2;

            return .{
                .size_pow2 = size_pow2,
                .vaddr = self.vaddrFromIndex(idx),
            };
        }

        fn isAllocationAllowed(self: *Self, size_pow2: usize) bool {
            return if (size_pow2 > self.free_mem_size) false else true;
        }

        // TODO implement ret_addr
        fn alloc(ctx: *anyopaque, len: usize, _: u8, _: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const len_pow2 = minAllocSize(len) catch return null;
            if (!self.isAllocationAllowed(len_pow2)) return null;

            const alloc_info = self.allocInner(len_pow2) catch return null;
            defer log.debug("alloc(): requested 0x{x} allocated: 0x{x}, free: 0x{x}", .{ len,  alloc_info.size_pow2, self.free_mem_size });

            return @as([*]u8, @ptrFromInt(alloc_info.vaddr));
        }

        fn freeInner(self: *Self, vaddr: usize) void {
            const idx = self.indexFromVaddr(vaddr);
            log.debug("free: idx: {d} from vaddr: {d}", .{ idx, vaddr });

            self.tree.unset(idx);
            self.tree.maybeUnsetParent(idx);

            const level_meta = self.tree.levelMetaFromIndex(idx) catch |err| {
                log.err("freeInner(): levelMetaFromIndex failed: {s}", .{err});
                @panic("freeInner(): levelMetaFromIndex failed");
            };
            self.free_mem_size += level_meta.size;
        }

        fn free(ctx: *anyopaque, old_mem: []u8, _: u8, _: usize) void {
            defer log.debug("free(): freed at 0x{x}", .{&old_mem[0]});
            const self: *Self = @ptrCast(@alignCast(ctx));
            const vaddr = @intFromPtr(old_mem.ptr);
            self.freeInner(vaddr);
        }

        /// Resize the allocation at the given virtual address to the new length. Note that resizing is limited to the current chunk.
        /// For example, if you allocated 3kB, it implies that we have occupied 4kB (page/frame size), so you can resize it to up to 4kB within this chunk.
        fn resizeInner(self: *Self, vaddr: usize, new_len: usize) bool {
            const idx = self.indexFromVaddr(vaddr);
            const new_size_pow2 = minAllocSize(new_len) catch return false;
            const old_size_pow2 = (self.tree.levelMetaFromIndex(idx) catch return false).size;
            if (new_size_pow2 <= old_size_pow2) return true; //no need to leave the chunk

            log.debug("resizeInner(): idx: {d}, old_size_pow2: {d}, new_size_pow2: {d}", .{ idx, old_size_pow2, new_size_pow2 });

            //can't resize without moving up in the tree (even if right buddy is free, we can't use it cause we should change idx to the parnet, wchich cause chaning the vaddr)
            return false;
        }

        fn resize(ctx: *anyopaque, buf: []u8, _: u8, new_len: usize, _: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const vaddr = @intFromPtr(&buf[0]);
            const res = self.resizeInner(vaddr, new_len);
            defer log.debug("resize(): resized: {} at 0x{x}, new_len: 0x{x}", .{ res, &buf[0], new_len });
            return res;
        }

        pub fn allocator(self: *Self) Allocator {
            return Allocator{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = Allocator.noResize,
                    .free = free,
                },
            };
        }

        test "BuddyAllocatorInner" {
            const tst_frame_size = 4;
            const tst_max_levels = 10;
            const tst_mem_size = 17;
            const tst_req_mem_size_pow2 = 4; //must be at least = tst_frame_size, cause allocInner does not control it
            const tst_req2_mem_size_pow2 = 8; //must be at least = tst_frame_size, cause allocInner does not control it

            var memory = [_]u8{0} ** 100; //we need only one byte to store Buddy Allocator bitmap somwhere there, but it takes 4 bytes

            const BuddyAlocator4Bytes = BuddyAllocator(tst_max_levels, tst_frame_size);
            var ba = try BuddyAlocator4Bytes.init(&memory, tst_mem_size);
            try t.expect(ba.tree.buffer[0] == 0b0000_1011); // buffer takes 1 byte, so 4 bytes is taken, the lowest bit is foor of the tree, 2nd bit is its left child, and so forth

            const alloc_info = try ba.allocInner(tst_req_mem_size_pow2);

            try t.expect(ba.unmanaged_mem_size == 1);
            try t.expect(alloc_info.size_pow2 == 4);
            try t.expect(ba.tree.buffer[0] == 0b0001_1011); // we  allocated 4 bytes, so now 8 bytes is taken

            ba.freeInner(alloc_info.vaddr);
            try t.expect(ba.tree.buffer[0] == 0b0000_1011); // now only buffer occupies 4 bytes

            const alloc_size2 = try ba.allocInner(tst_req2_mem_size_pow2);

            try t.expect(alloc_size2.size_pow2 == 8);
            try t.expect(ba.tree.buffer[0] == 0b0110_1111); // now  we occupied 12 bytes, 4 bytes is free
        }
    };
}

test "BuddyAllocator" {
    const tst_frame_size = 4;
    const tst_max_levels = 11;
    const tst_mem_size = 17;
    const tst_req_mem_size = 2;

    var memory = [_]u8{0} ** 100; //we need only one byte to store Buddy Allocator bitmap somwhere there, but it takes 4 bytes

    const BuddyAlocator4Bytes = BuddyAllocator(tst_max_levels, tst_frame_size);
    var ba = try BuddyAlocator4Bytes.init(&memory, tst_mem_size);
    try t.expect(ba.tree.buffer[0] == 0b0000_1011); // buffer takes 1 byte, so 4 bytes is taken, the lowest bit is foor of the tree, 2nd bit is its left child, and so forth
    try t.expect(ba.unmanaged_mem_size == 1);

    const allocator = ba.allocator();

    const alloc_mem = try allocator.alloc(u8, tst_req_mem_size);
    try t.expect(ba.tree.buffer[0] == 0b0001_1011); // we  allocated 4 bytes, so now 8 bytes is taken

    allocator.free(alloc_mem);
    try t.expect(ba.tree.buffer[0] == 0b0000_1011); // now only buffer occupies 4 bytes
}
