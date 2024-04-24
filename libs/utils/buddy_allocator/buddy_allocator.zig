//! Buddy Allocator
//! This is an implementation of a buddy allocator. It is based on the bitmap tree implementation.
//! The allocator allocates memory for internal BuddyBitmapTree buffer and for the client allocations using the same mechanism.
//! That's why no additional memory outside the given memory is needed.
const std = @import("std");
const bbtree = @import("bbtree.zig");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.buddy_allocator);
const assert = std.debug.assert;
const t = std.testing;

pub fn BuddyAllocator(comptime max_levels: u8, comptime min_size: usize) type {
    const BBTree = bbtree.BuddyBitmapTree(max_levels, min_size);

    const AllocInfo = struct {
        // allocated_mem_size: usize,
        // free_mem_size: usize,

        size_pow2: usize, //allocated memory
        vaddr: usize, //virtual address
    };

    return struct {
        const Self = @This();

        tree: BBTree = undefined,
        unalloc_mem_size: usize = undefined,
        max_mem_size_pow2: usize = undefined,
        free_mem_size: usize = undefined,
        mem_vaddr: usize = undefined, //start of the memory to be managed the allocator

        fn allocBuffer(self: *Self, size: usize) !void {
            const level_meta = self.tree.levelMetaFromSize(size) catch return error.OutOfMemory;
            const buffer_index = level_meta.offset;
            const buffer_vaddr = self.vaddrFromIndex(level_meta.offset);
            const buffer: []u8 = @as([*]u8, @ptrFromInt(buffer_vaddr))[0..self.tree.meta.len];
            self.tree.setBuffer(buffer);
            self.tree.setChunk(buffer_index);
        }

        pub fn init(memory: []u8) !Self {
            assert(memory.len >= BBTree.frame_size);
            const max_pow2 = std.math.floorPowerOfTwo(usize, memory.len);
            var self = Self{
                .unalloc_mem_size = memory.len - max_pow2,
                .max_mem_size_pow2 = max_pow2,
                .free_mem_size = max_pow2,
                .tree = try BBTree.init(max_pow2),
                .mem_vaddr = @intFromPtr(memory.ptr),
            };

            log.debug("bbt: {}", .{self.tree.meta});

            // meta.len holds the size (number of bytes) of bitmap we need
            const min_buffer_size = @max(self.tree.meta.len, BBTree.frame_size); // if e.g. metal.len=1B -> 4kB (for frame_size = 4kB)
            try allocBuffer(&self, min_buffer_size); //allocate place for the bitmap buffer using the same mechanism as for the future client allocations

            return self;
        }

        fn vaddrFromIndex(self: Self, idx: usize) usize {
            return self.mem_vaddr + BBTree.frame_size * idx;
        }

        fn indexFromVaddr(self: Self, vaddr: usize) usize {
            return (vaddr - self.mem_vaddr) / BBTree.frame_size;
        }

        inline fn minAllocSize(size: usize) !usize {
            return try std.math.ceilPowerOfTwo(usize, @max(BBTree.frame_size, size)); //e.g. 1->4, 16 -> 16, but 17,18,... -> 32
        }

        pub fn allocInner(self: *Self, size_pow2: usize) !AllocInfo {
            const idx = (self.tree.freeIndexFromSize(size_pow2)) catch return error.OutOfMemory;
            log.debug("idx: {d}", .{idx});

            self.tree.setChunk(idx);

            self.tree.dump();

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
            return @as([*]u8, @ptrFromInt(alloc_info.vaddr));
        }

        fn freeInner(self: *Self, vaddr: usize) void {
            const idx = self.indexFromVaddr(vaddr);
            log.debug("free: {d} from vaddr: {d}", .{ idx, vaddr });

            self.tree.unset(idx);
            self.tree.maybeUnsetParent(idx);

            self.tree.dump();
        }

        fn free(ctx: *anyopaque, old_mem: []u8, _: u8, _: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const vaddr = @intFromPtr(&old_mem[0]);
            self.freeInner(vaddr);
        }

        // TODO implement resize
        fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
            return false;
        }

        pub fn allocator(self: *Self) Allocator {
            return Allocator{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize =  Allocator.noResize,
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

            try t.expect(ba.unalloc_mem_size == 1);
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
    try t.expect(ba.unalloc_mem_size == 1);

    const allocator = ba.allocator();

    const alloc_mem = try allocator.alloc(u8, tst_req_mem_size);
    //try t.expect(alloc_mem > 0); // we  allocated 4 bytes, so now 8 bytes is taken
    try t.expect(ba.tree.buffer[0] == 0b0001_1011); // we  allocated 4 bytes, so now 8 bytes is taken

    allocator.free(alloc_mem);
    try t.expect(ba.tree.buffer[0] == 0b0000_1011); // now only buffer occupies 4 bytes
}
