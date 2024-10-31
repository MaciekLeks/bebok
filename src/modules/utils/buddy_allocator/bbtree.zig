//! BuddyBitmapTree
//! A buddy bitmap tree implementation in Zig
//! Levels count from 0, the root is level 0, and has got 1 bit
//!  If the highest level is 2, and the minimum chunk size is 4kB, them L0 is 16kB at the 0 level, L1 is 8kB at the 1 level,
//!  In this case client allocates 4kB, the tree will look like this:
//!  L0                             1
//!  L1             1                               0
//!  L2       1           0               0           0

const std = @import("std");
const math = std.math;

const log = std.log.scoped(.bbtree);
const assert = std.debug.assert;

pub fn BuddyBitmapTree(comptime max_levels: u8, comptime min_chunk_size: usize) type {
    return struct {
        const Self = @This();

        /// Holds metadata for a level
        pub const LevelMetadata = struct {
            bit_offset: usize, // offset of the level in the bitmap
            size: usize, // size of the chunk at the level
            bit_count: usize, // number of bits in the level
        };

        /// Holds metadata for the bitmap
        pub const Metadata = struct {
            level_count: u8,
            level_meta: []LevelMetadata,
            bit_count: usize, //bits needed
            len: usize, //bytes len needed to store bits

            fn buildLevelMeta(level_count: u8) ![]LevelMetadata {
                for (0..level_count) |lvl| {
                    level_meta[lvl] = .{ .bit_offset = (math.powi(usize, 2, lvl) catch return error.InvalidLevel) - 1, .size = page_size * (math.powi(usize, 2, level_count - lvl - 1) catch return error.InvalidSize), .bit_count = math.powi(usize, 2, lvl) catch return error.BitOverflow };
                }
                return level_meta[0..level_count];
            }

            pub fn init(max_size_pow2: usize, min_size_pow2: usize) !Metadata {
                const level_count: u8 = @intCast(math.log2(max_size_pow2 / min_size_pow2) + 1); // number of levels: 0 < level <= max_level, 0,1,2 counts as 3 levels
                const bit_count = try bitsFromLevels(level_count);
                return .{
                    .level_count = level_count,
                    .level_meta = try buildLevelMeta(level_count),
                    .bit_count = bit_count,
                    .len = bytesFromBits(bit_count),
                };
            }

            pub inline fn levelFromSize(self: *Metadata, size_pow2: usize) !u8 {
                const norm_size_pow2 = size_pow2 / page_size;
                //std.debug.print("levelFromSize(): size_pow2: {d}, page_size: {d}, norm_size_pow2: {d}\n", .{ size_pow2, page_size, norm_size_pow2 });
                assert(norm_size_pow2 >= 1);
                const computed_level = self.level_count - math.log2(norm_size_pow2) - 1;
                log.debug("levelFromSize(): size: {d}, level: {d}", .{ size_pow2, computed_level });
                return if (computed_level > self.level_count) error.InvalidSize else @intCast(computed_level);
            }

            pub fn levelMetaFromSize(self: *Metadata, size_pow2: usize) !LevelMetadata {
                const level = try self.levelFromSize(size_pow2);
                return self.level_meta[level];
            }

            pub fn dupe(self: *Metadata, allocator: std.mem.Allocator) !*Metadata {
                const meta = try allocator.create(Metadata);
                meta.* = .{
                    .level_count = self.level_count,
                    .level_meta = try allocator.dupe(LevelMetadata, self.level_meta),
                    .bit_count = self.bit_count,
                    .len = self.len,
                };
                return meta;
            }

            pub fn deinit(self: *Metadata, allocator: std.mem.Allocator) void {
                allocator.free(self.level_meta);
                allocator.free(self);
            }
        };

        buffer: []u8 = undefined, // buffer to store bits
        meta: *Metadata,

        pub const page_size = math.floorPowerOfTwo(usize, min_chunk_size);
        pub var level_meta: [max_levels]LevelMetadata = undefined;

        inline fn bytesFromBits(bits: usize) usize {
            return (bits + 7) / 8;
        }

        inline fn bitsFromLevels(level_count: u8) !usize {
            return try math.powi(usize, 2, level_count) - 1;
        }

        /// Initialize the metadata only, no buffer is allocated cause we do not know the right place to store it
        pub fn init(allocator: std.mem.Allocator, meta: *Metadata, buf: []u8) !*Self {
            const self = try allocator.create(Self);
            self.* = .{ .meta = meta, .buffer = buf };
            return self;
        }

        // indx: 0..bits
        pub fn isSet(self: *const Self, idx: usize) bool {
            assert(idx < self.meta.bit_count);
            const byte = idx / 8;
            const bit_val = (self.buffer[idx / 8] & (@as(u8, 1) << @intCast(idx % 8)));
            log.debug("isSet bit idx: {d} with bit val:  {b:0>8} in {b:0>8}", .{ idx, bit_val, self.buffer[byte] });
            //std.debug.print("isSet bit idx: {d} with bit val:  {b:0>8} in {b:0>8}", .{ idx, bit_val, self.buffer[byte] });
            return (self.buffer[idx / 8] & (@as(u8, 1) << @intCast(idx % 8))) != 0;
        }

        pub fn set(self: *Self, idx: usize) void {
            assert(idx < self.meta.bit_count);
            const bit_mask = @as(u8, 1) <<| @as(u8, @intCast(idx % 8));
            const byte = idx / 8;
            self.buffer[idx / 8] |= (@as(u8, 1) << @intCast(idx % 8));
            log.debug("set bit idx: {d} with mask:  {b:0>8}/{d} in byte: {d}", .{ idx, bit_mask, bit_mask, byte });
            //std.debug.print("set bit idx: {d} with mask:  {b:0>8}/{d} in byte: {d}\n", .{ idx, bit_mask, bit_mask, byte });
        }

        pub fn unset(self: *Self, idx: usize) void {
            assert(idx < self.meta.bit_count);
            self.buffer[idx / 8] &= ~(@as(u8, 1) << @intCast(idx % 8));
        }

        pub fn dump(self: *Self) void {
            for (0..self.meta.len) |i| {
                const v = self.buffer[i];
                log.debug("bitmap: {b:0>8}/{d}", .{ v, v });
            }
        }

        inline fn buddyIndex(idx: usize) ?usize {
            if (idx == 0) return null;
            if (idx % 2 == 0) {
                log.debug("buddyIndex for idx: {d} is {d}", .{ idx, idx - 1 });
                return idx - 1;
            } else {
                log.debug("buddyIndex for idx: {d} is {d}", .{ idx, idx + 1 });
                return idx + 1;
            }
        }

        inline fn parentIndex(idx: usize) usize {
            assert(idx > 0);
            log.debug("parentIndex: {d}", .{(idx - 1) / 2});
            return (idx - 1) / 2; //todo +1?
        }

        inline fn leftChildIndex(idx: usize) usize {
            log.debug("leftChildIndex: {d}", .{(idx + 1) * 2 - 1});
            return (idx + 1) * 2 - 1;
        }

        inline fn rightChildIndex(idx: usize) usize {
            log.debug("rightChildIndex: {d}", .{(idx + 1) * 2});
            return (idx + 1) * 2;
        }

        pub inline fn levelFromIndex(idx: usize) u8 {
            return math.log2_int(usize, idx + 1); // we need to add 1 to the index to get the level, log2(0+1) ->level 0, log2(1+1) -> level 1, log2(14+1) -> level 3
        }

        pub inline fn levelMetaFromIndex(self: *Self, idx: usize) !LevelMetadata {
            const level = levelFromIndex(idx);
            return self.meta.level_meta[level];
        }

        pub inline fn levelFromSize(self: *Self, size_pow2: usize) !u8 {
            // const norm_size_pow2 =size_pow2 / frame_size;
            // assert(norm_size_pow2 >= 1);
            // log.debug("log2(size_pow2 / frame_size) = {d}", .{ math.log2(norm_size_pow2) });
            // const computed_level = self.meta.level_count - math.log2(norm_size_pow2) - 1;
            // return if (computed_level > self.meta.level_count) error.InvalidSize else @intCast(computed_level);
            return self.meta.levelFromSize(size_pow2);
        }

        pub fn levelMetaFromSize(self: *Self, size_pow2: usize) !LevelMetadata {
            //const level = try levelFromSize(self, size_pow2);
            //return self.meta.level_meta[level];
            return self.meta.levelMetaFromSize(size_pow2);
        }

        pub fn freeIndexFromSize(self: *Self, size_pow2: usize) !usize {
            assert(size_pow2 > 0);
            //std.debug.print("freeIndexFromSize(): {d} self: {}\n", .{ size_pow2, self.meta });
            log.debug("freeIndexFromSize(): {d} self: {}", .{ size_pow2, self.meta });
            const level = try self.levelFromSize(size_pow2);
            const start_offset = self.meta.level_meta[level].bit_offset;
            const end_offset = start_offset + self.meta.level_meta[level].bit_count;

            log.debug("freeIndexFromSize(): size: {d} level: {d} start: {d} end: {d}", .{ size_pow2, level, start_offset, end_offset });
            //std.debug.print("freeIndexFromSize(): size: {d} level: {d} start: {d} end: {d}\n", .{ size_pow2, level, start_offset, end_offset });

            const idx = for (start_offset..end_offset) |i| {
                if (!self.isSet(i)) {
                    break i;
                }
            } else {
                return error.InvalidSize;
            };

            return idx;
        }

        pub fn maybeUnsetParent(self: *Self, idx: usize) void {
            if (idx == 0) return;
            const buddy_idx = buddyIndex(idx);
            if (buddy_idx) |bidx| {
                if (self.isSet(bidx)) {
                    log.debug("buddy is set: {d}; nothing to do", .{bidx});
                    return;
                } else {
                    log.debug("buddy is not set: {d}, we can merge chunks", .{bidx});
                    const parent_idx = parentIndex(idx);
                    self.unset(parent_idx); //parent is allocable
                    self.maybeUnsetParent(parent_idx); //check parent's parent
                }
            }
        }

        // Recursively set bits for parent and its parents
        pub fn setParent(self: *Self, idx: usize) void {
            if (idx == 0) {
                //std.debug.print("[1]\n", .{});
                return;
            }

            const parent_idx = parentIndex(idx);

            //std.debug.print("setParent: {d} parent: {d}\n", .{ idx, parent_idx });

            if (self.isSet(parent_idx)) {
                //std.debug.print("[2]\n", .{});
                return;
            } else {
                self.set(parent_idx);
                self.setParent(parent_idx);
            }
        }

        /// Recursively set bits for the children of the chunk
        pub fn setChildren(self: *Self, idx: usize) void {
            const level = levelFromIndex(idx);

            log.debug("setChildren: {d} level: {d}", .{ idx, level });
            //std.debug.print("setChildren: {d} level: {d}\n", .{ idx, level });
            if (level + 1 >= self.meta.level_count) return;

            const left_child = leftChildIndex(idx);
            const right_child = rightChildIndex(idx);

            self.set(left_child);
            self.set(right_child);

            self.setChildren(left_child);
            self.setChildren(right_child);
        }

        // Recursively set bits for the chunk, its parent and children
        pub inline fn setChunk(self: *Self, idx: usize) void {
            self.set(idx);
            self.setParent(idx);
            self.setChildren(idx);
        }

        // Index occupies the chunk if it's children are set
        // inline fn isOccupingIndex(self: *const Self, idx: usize) bool {
        //     if (!self.isSet(idx)) {
        //         return false;
        //     }
        //
        //     const level = levelFromIndex(idx);
        //     if (level + 1 >= self.meta.level_count) return true;
        //
        //     const left_child = leftChildIndex(idx);
        //     const right_child = rightChildIndex(idx);
        //
        //     return self.isSet(left_child) and self.isSet(right_child);
        // }
        //
        // // Find real occupied index in the bitmap by the index of the chunk
        // // It works only up to the root
        // pub fn findOccupyingIndexByChunkIndex(self: *const Self, idx: usize) !usize {
        //     const is_occupant_idx = self.isOccupingIndex(idx);
        //
        //     log.debug("findOccupyingIndexByChunkIndex: {d} is_occupant_idx: {}", .{ idx, is_occupant_idx });
        //
        //     if (idx == 0) {
        //         return idx;
        //     }
        //
        //     // check if parent is occupant too, if yes go up, otherwise return the current index
        //     const parent_idx = parentIndex(idx);
        //     if (is_occupant_idx) {
        //         return self.findOccupyingIndexByChunkIndex(parent_idx);
        //     } else {
        //         return idx;
        //     }
        // }
    };
}
