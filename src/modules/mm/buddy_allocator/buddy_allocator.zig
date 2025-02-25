//! Self-allocating Buddy Allocator
//! This is an implementation of a buddy allocator based on the bitmap tree architecture.
//! The allocator uses the same mechanism for two purposes: Allocating memory for the internal BuddyBitmapTree buffer and for client allocations.
//! This means it doesn't require any additional memory beyond the resources initially provided.
const std = @import("std");
const bbtree = @import("bbtree.zig");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const log = std.log.scoped(.buddy_allocator);
const metric_log = std.log.scoped(.metric_mem);
const assert = std.debug.assert;
const t = std.testing;

pub fn BuddyAllocator(comptime max_levels: u8, comptime min_size: usize) type {
    const BBTree = bbtree.BuddyBitmapTree(max_levels, min_size);

    const AllocInfo = struct {
        size_pow2: usize, //allocated memory
        virt: usize, //virtual address
    };

    return struct {
        const Self = @This();

        tree: *BBTree = undefined,
        unmanaged_mem_size: usize = undefined,
        max_mem_size_pow2: usize = undefined,
        free_mem_size: usize = undefined,
        mem_virt: usize = undefined, //start of the memory to be managed the allocator
        metric_mem_allocated_block_count: usize = 0, //keep track of the allocated blocks

        // Initialize the allocator with the given memory by allocating the buffer for the tree and self object in that memory.
        pub fn init(mem: []u8) !*Self {
            assert(mem.len >= BBTree.page_size);
            const mem_max_size_pow2 = std.math.floorPowerOfTwo(usize, mem.len);

            // config on the stack
            var config = try BBTree.Metadata.init(mem_max_size_pow2, BBTree.page_size);

            //std.debug.print("\nConfig: {}\n", .{config});

            const self_size = @sizeOf(Self);
            const tree_size = @sizeOf(BBTree);
            const tree_buffer_size = config.len;
            const tree_meta_level_size = config.level_meta.len * @sizeOf(BBTree.LevelMetadata);
            // minimal size is the sum of the size of the self object, the size of the buffer, and the size of the tree
            const min_size_needed = self_size + @alignOf(Self) + tree_buffer_size + @alignOf([]u8) + tree_size + @alignOf(BBTree) + tree_meta_level_size + @alignOf(BBTree.LevelMetadata); // we added alignments just in caase
            const size_needed = @max(min_size_needed, BBTree.page_size);
            const size_needed_pow2 = try std.math.ceilPowerOfTwo(usize, size_needed);
            //log everuthing from min_sel_size to size_needed_pow2
            log.debug("init:   self_size: 0x{x}  buffer_size: 0x{x}  size_needed: 0x{x}  size_needed: 0x{x}  size_needed_pow2: 0x{x}, frame/page_size: 0x{x}", .{ self_size, tree_buffer_size, min_size_needed, size_needed, size_needed_pow2, BBTree.page_size });

            assert(mem.len >= size_needed_pow2);

            // get vaddr
            const level_meta = config.levelMetaFromSize(size_needed_pow2) catch return error.OutOfMemory;
            //std.debug.print("\nLevel meta: {} for size needed pow2: {d}\n", .{ level_meta, size_needed_pow2 });

            const self_index = level_meta.bit_offset;
            const virt = @intFromPtr(mem.ptr);
            const start_vaddr = try absVaddrFromIndex(virt, level_meta.bit_offset, level_meta); //we do not have self yet
            const self_mem: []u8 = @as([*]u8, @ptrFromInt(start_vaddr))[0..size_needed_pow2];

            var fba = std.heap.FixedBufferAllocator.init(self_mem);
            const fba_allocator = fba.allocator();

            // move config on the heap, and create the tree
            const tree_buffer = try fba_allocator.alloc(u8, tree_buffer_size);
            @memset(tree_buffer, 0);
            const tree = try BBTree.init(fba_allocator, try config.dupe(fba_allocator), tree_buffer);

            const self = try fba_allocator.create(Self);
            self.* = .{
                .unmanaged_mem_size = mem.len - mem_max_size_pow2,
                .max_mem_size_pow2 = mem_max_size_pow2,
                .free_mem_size = mem_max_size_pow2,
                .tree = tree,
                .mem_virt = virt,
            };

            self.tree.setChunk(self_index);
            self.free_mem_size -= level_meta.size;

            return self;
        }

        inline fn absVaddrFromIndex(virt: usize, idx: usize, level_meta: BBTree.LevelMetadata) !usize {
            return virt + level_meta.size * (idx - level_meta.bit_offset);
        }

        inline fn virtFromIndex(self: Self, idx: usize) !usize {
            const level_meta = try self.tree.levelMetaFromIndex(idx);

            //return self.mem_vaddr + level_meta.size * (idx - level_meta.offset);
            return absVaddrFromIndex(self.mem_virt, idx, level_meta);
        }

        inline fn indexFromSlice(self: *Self, old_mem: []u8) !usize {
            const virt_start = @intFromPtr(old_mem.ptr);
            const virt_end = virt_start + old_mem.len - 1;

            if (virt_start < self.mem_virt or virt_end > self.mem_virt + self.max_mem_size_pow2) return error.OutOfMemory;

            log.debug("indexFromSlice(): virt_start: 0x{x}, virt_end: 0x{x}, len: 0x{x}", .{ virt_start, virt_end, virt_end - virt_start });

            const len_pow2 = minAllocSize(old_mem.len) catch return error.OutOfMemory;
            const level_meta = self.tree.levelMetaFromSize(len_pow2) catch return error.OutOfMemory;

            log.debug("indexFromSlice(): len_pow2: 0x{x}, level_meta: {}", .{ len_pow2, level_meta });

            //Try to find out it's a right allocated level to free, becasue user could reslice primary allocated memory, e.g. 0x4000 (allocated) -> 0x800 (freed)
            //So we need to find out the right level to free
            const virt_down_aligned = virt_start & ~(level_meta.size - 1);

            log.debug("indexFromSlice(): virt_down_aligned: 0x{x}", .{virt_down_aligned});

            const idx = (virt_down_aligned - self.mem_virt + level_meta.bit_offset * level_meta.size) / level_meta.size;

            //can't use this cause we can free memory allocated by someone else
            //const occupator_idx = try self.tree.findOccupyingIndexByChunkIndex(idx);
            log.debug("indexFromSlice(): idx: {d}", .{idx});

            return idx;
        }

        pub inline fn minAllocSize(size: usize) !usize {
            return try std.math.ceilPowerOfTwo(usize, @max(BBTree.page_size, size)); //e.g. 1->4, 16 -> 16, but 17,18,... -> 32
        }

        fn metric_mem_allocated_block_count_up(self: *Self, size_pow2: usize) void {
            const allocated_block_count = size_pow2 / min_size;
            self.metric_mem_allocated_block_count += allocated_block_count;
            metric_log.debug("Up: +{d}, Current: {d}", .{ allocated_block_count, self.metric_mem_allocated_block_count });
        }

        fn metric_mem_allocated_block_count_down(self: *Self, size_pow2: usize) void {
            const allocated_block_count = size_pow2 / min_size;
            self.metric_mem_allocated_block_count -= allocated_block_count;
            metric_log.debug("Down: -{d}, Current: {d}", .{ allocated_block_count, self.metric_mem_allocated_block_count });
        }

        pub fn allocInner(self: *Self, size_pow2: usize) !AllocInfo {
            const idx = (self.tree.freeIndexFromSize(size_pow2)) catch return error.OutOfMemory;
            log.debug("allocInner(): idx: {d} for size: 0x{x}", .{ idx, size_pow2 });
            //std.debug.print("\nAllocInner: idx: {d} for size: 0x{x}\n", .{ idx, size_pow2 });

            self.tree.setChunk(idx);

            //self.tree.dump();

            self.free_mem_size -= size_pow2;

            //metrics
            self.metric_mem_allocated_block_count_up(size_pow2);

            return .{
                .size_pow2 = size_pow2,
                .virt = try self.virtFromIndex(idx),
            };
        }

        fn isAllocationAllowed(self: *Self, size_pow2: usize) bool {
            return if (size_pow2 > self.free_mem_size) false else true;
        }

        // TODO implement ret_addr
        fn alloc(ctx: *anyopaque, len: usize, _: Alignment, _: usize) ?[*]u8 {
            log.debug("alloc(): requested 0x{x}", .{len});
            const self: *Self = @ptrCast(@alignCast(ctx));
            const len_pow2 = minAllocSize(len) catch return null;
            //std.debug.print("\nAlloc: len_pow2 {}\n", .{len_pow2});
            if (!self.isAllocationAllowed(len_pow2)) return null;

            const alloc_info = self.allocInner(len_pow2) catch return null;
            defer log.debug("alloc(): requested 0x{x} allocated: 0x{x}, free: 0x{x} at: 0x{x}", .{ len, alloc_info.size_pow2, self.free_mem_size, alloc_info.virt });

            return @as([*]u8, @ptrFromInt(alloc_info.virt));
        }

        fn freeInner(self: *Self, old_mem: []u8) void {
            const idx = self.indexFromSlice(old_mem) catch |err| {
                log.err("freeInner(): indexFromSlice failed: {}", .{err});
                @panic("freeInner(): indexFromSlice failed");
            };

            log.debug("free: idx: {d} from vaddr: 0x{*}", .{ idx, old_mem.ptr });

            self.tree.unset(idx);
            self.tree.maybeUnsetParent(idx);

            const level_meta = self.tree.levelMetaFromIndex(idx) catch |err| {
                log.err("freeInner(): levelMetaFromIndex failed: {s}", .{err});
                @panic("freeInner(): levelMetaFromIndex failed");
            };
            self.free_mem_size += level_meta.size;

            //metrics
            self.metric_mem_allocated_block_count_down(level_meta.size);
        }

        fn free(ctx: *anyopaque, old_mem: []u8, _: Alignment, _: usize) void {
            log.debug("free(): Freeing slice  {*} of 0x{x} len", .{ old_mem.ptr, old_mem.len });
            defer log.debug("free(): Freed at 0x{x}", .{&old_mem[0]});
            const self: *Self = @ptrCast(@alignCast(ctx));
            //const vaddr = @intFromPtr(old_mem.ptr);
            self.freeInner(old_mem);
        }

        /// Resize the allocation at the given virtual address to the new length. Note that resizing is limited to the current chunk.
        /// For example, if you allocated 3kB, it implies that we have occupied 4kB (page/frame size), so you can resize it to up to 4kB within this chunk.
        fn resizeInner(self: *Self, old_mem: []u8, new_len: usize) bool {
            const idx = self.indexFromSlice(old_mem) catch |err| {
                log.err("resizeInner(): indexFromSlice failed: {}", .{err});
                @panic("resizeInner(): indexFromSlice failed");
            };

            const new_size_pow2 = minAllocSize(new_len) catch return false;
            const old_size_pow2 = (self.tree.levelMetaFromIndex(idx) catch return false).size;
            if (new_size_pow2 <= old_size_pow2) return true; //no need to leave the chunk

            log.debug("resizeInner(): idx: {d}, old_size_pow2: {d}, new_size_pow2: {d}", .{ idx, old_size_pow2, new_size_pow2 });

            //can't resize without moving up in the tree (even if right buddy is free, we can't use it cause we should change idx to the parnet, wchich cause chaning the vaddr)
            return false;
        }

        fn resize(ctx: *anyopaque, buf: []u8, _: Alignment, new_len: usize, _: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const res = self.resizeInner(buf, new_len);
            defer log.debug("resize(): resized: {} at 0x{x}, new_len: 0x{x}", .{ res, &buf[0], new_len });
            return res;
        }

        pub fn allocator(self: *Self) Allocator {
            return Allocator{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .remap = Allocator.noRemap, //TODO: to be define - it was addd at the end of 0.14th version development
                    .free = free,
                },
            };
        }

        test "BuddyAllocatorInner" {
            const tst_frame_size = 0x1000;
            const tst_max_levels = 4;
            const tst_mem_size = 0x4000;
            //const tst_req_mem_size_pow2 = 4; //must be at least = tst_frame_size, cause allocInner does not control it
            //const tst_req2_mem_size_pow2 = 8; //must be at least = tst_frame_size, cause allocInner does not control it

            var memory = [_]u8{0} ** tst_mem_size; //we need only one byte to store Buddy Allocator bitmap somwhere there, but it takes 4 bytes

            const BuddyAlocator4Bytes = BuddyAllocator(tst_max_levels, tst_frame_size);
            const ba = try BuddyAlocator4Bytes.init(&memory);
            try t.expect(ba.tree.buffer[0] == 0b0000_1011); // buffer takes 1 byte, so 4 bytes is taken, the lowest bit is foor of the tree, 2nd bit is its left child, and so forth

            // the above not works in the test (it works in the kernel only)
            // const alloc_info = try ba.allocInner(tst_req_mem_size_pow2);
            //
            // try t.expect(ba.unmanaged_mem_size == 1);
            // try t.expect(alloc_info.size_pow2 == 4);
            // try t.expect(ba.tree.buffer[0] == 0b0001_1011); // we  allocated 4 bytes, so now 8 bytes is taken
            //
            // ba.freeInner(alloc_info.vaddr);
            // try t.expect(ba.tree.buffer[0] == 0b0000_1011); // now only buffer occupies 4 bytes
            //
            // const alloc_size2 = try ba.allocInner(tst_req2_mem_size_pow2);
            //
            // try t.expect(alloc_size2.size_pow2 == 8);
            // try t.expect(ba.tree.buffer[0] == 0b0110_1111); // now  we occupied 12 bytes, 4 bytes is free
        }
    };
}

test "BuddyAllocator" {
    const tst_frame_size = 0x1000;
    const tst_max_levels = 3;
    const tst_mem_size = 0x4000;
    //const tst_req_mem_size = 2;

    var memory = [_]u8{0} ** tst_mem_size; //we need only one byte to store Buddy Allocator bitmap somwhere there, but it takes 4 bytes

    const BuddyAlocator4Bytes = BuddyAllocator(tst_max_levels, tst_frame_size);
    const ba = try BuddyAlocator4Bytes.init(&memory);
    //std.debug.print("\nBUFFER: 0b{b}\n", .{ba.tree.buffer[0]});
    try t.expect(ba.tree.buffer[0] == 0b0000_1011); // buffer takes 1 byte, so 1 page is taken is taken, the lowest bit is root of the tree, 2nd bit is its left child, and so forth

    // the above not works in the test (it works in the kernel only)
    // const allocator = ba.allocator();
    //
    // //std.debug.print("\nBUFFER2: 0b{b}\n", .{ba.tree.buffer[0]});
    // const alloc_mem = try allocator.alloc(u8, tst_req_mem_size);
    // //std.debug.print("\nBUFFER3: 0b{b}\n", .{ba.tree.buffer[0]});
    // //std.debug.print("\nBUFFER3: {}\n", .{ba});
    // try t.expect(ba.tree.buffer[0] == 0b0001_1011); // we  allocated 4 bytes, so now 8 bytes is taken
    //
    // allocator.free(alloc_mem);
    // try t.expect(ba.tree.buffer[0] == 0b0000_1011); // now only buffer occupies 4 bytes
}
