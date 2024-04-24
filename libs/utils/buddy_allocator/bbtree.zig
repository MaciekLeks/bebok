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
        const LevelMetadata = struct {
            offset: usize, // offset of the level in the bitmap
            size: usize, // size of the chunk at the level
            bits: usize, // number of bits in the level
        };

        /// Holds metadata for the bitmap
        pub const Metadata = struct {
            level_count: u8,
            level_meta: []LevelMetadata,
            bit_count: usize, //bits needed
            len: usize, //bytes len needed to store bits

            pub fn init(max_size_pow2: usize, min_size_pow2: usize) !@This() {
                const level_count: u8 = @intCast(math.log2(max_size_pow2 / min_size_pow2) + 1); // number of levels: 0 < level <= max_level, 0,1,2 counts as 3 levels
                const bit_count = try bitsFromLevels(level_count);
                return .{
                    .level_count = level_count,
                    .level_meta = try buildLevelMeta(level_count),
                    .bit_count = bit_count,
                    .len = bytesFromBits(bit_count),
                };
            }
        };

        buffer: []u8 = undefined, // buffer to store bits
        meta: Metadata,

        pub const frame_size = math.floorPowerOfTwo(usize, min_chunk_size);
        pub var level_meta: [max_levels]LevelMetadata = undefined;

        inline fn bytesFromBits(bits: usize) usize {
            return (bits + 7) / 8;
        }

        inline fn bitsFromLevels(level_count: u8) !usize {
            return try math.powi(usize, 2, level_count) - 1;
        }

        fn buildLevelMeta(level_count: u8) ![]LevelMetadata {
            for (0..level_count) |lvl| {
                level_meta[lvl] = .{ .offset = (math.powi(usize, 2, lvl) catch return error.InvalidLevel) - 1, .size = frame_size * (math.powi(usize, 2, level_count - lvl - 1) catch return error.InvalidSize), .bits = math.powi(usize, 2, lvl) catch return error.BitOverflow };
            }
            return level_meta[0..level_count];
        }

        /// Initialize the metadata only, no buffer is allocated cause we do not know the right place to store it
        pub fn init(max_size_pow2: usize) !Self {
            return .{ .meta = try Metadata.init(max_size_pow2, frame_size) };
        }

        // Set the buffer to store the bits
        pub fn setBuffer(self: *Self, buffer: []u8) void {
            log.debug("metadata: init: {d} levels, {d} bits, {d} bytes", .{ self.meta.level_count, self.meta.bit_count, self.meta.len });

            self.buffer = buffer;
        }

        // indx: 0..bits
        pub fn isSet(self: *const Self, idx: usize) bool {
            assert(idx < self.meta.bit_count);
            const byte = idx / 8;
            const bit_val = (self.buffer[idx / 8] & (@as(u8, 1) << @intCast(idx % 8)));
            log.debug("isSet bit idx: {d} with bit val:  {b:0>8} in {b:0>8}", .{ idx, bit_val, self.buffer[byte] });
            return (self.buffer[idx / 8] & (@as(u8, 1) << @intCast(idx % 8))) != 0;
        }

        pub fn set(self: *Self, idx: usize) void {
            assert(idx < self.meta.bit_count);
            const bit_mask = @as(u8, 1) <<| @as(u8, @intCast(idx % 8));
            const byte = idx / 8;
            self.buffer[idx / 8] |= (@as(u8, 1) << @intCast(idx % 8));
            log.debug("set bit idx: {d} with mask:  {b:0>8}/{d} in byte: {d}", .{ idx, bit_mask, bit_mask, byte });
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
                log.debug("buddyIndex for idx: {d} is {d}", .{idx, idx - 1});
                return idx - 1;
            } else {
                log.debug("buddyIndex for idx: {d} is {d}", .{idx, idx + 1});
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

        inline fn levelFromIndex(idx: usize) u8 {
            return if (idx == 0) return 0 else {
                log.debug("level {d} from index: {d}", .{ math.log2_int_ceil(usize, idx), idx });
                return math.log2_int_ceil(usize, idx);
            };
        }

        pub inline fn levelFromSize(self: *Self, size_pow2: usize) !u8 {
            const norm_size_pow2 =size_pow2 / frame_size;
            assert(norm_size_pow2 >= 1);
            log.debug("log2(size_pow2 / frame_size) = {d}", .{ math.log2(norm_size_pow2) });
            const computed_level = self.meta.level_count - math.log2(norm_size_pow2) - 1;
            return if (computed_level > self.meta.level_count) error.InvalidSize else @intCast(computed_level);
        }

        pub fn levelMetaFromSize(self: *Self, size_pow2: usize) !LevelMetadata {
            const level = try levelFromSize(self, size_pow2);
            return self.meta.level_meta[level];
        }

        pub fn freeIndexFromSize(self: *Self, size_pow2: usize) !usize {
            assert(size_pow2 > 0);
            //log.debug("freeIndexFromSize: {d} self: {}", .{ size_pow2, self.meta });
            const level = try self.levelFromSize(size_pow2);
            const start_offset = self.meta.level_meta[level].offset;
            const end_offset = start_offset + self.meta.level_meta[level].bits;

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

        // Recursively unset bits for parent and its parents
        pub fn setParent(self: *Self, idx: usize) void {
            if (idx == 0) return;

            const parent_idx = parentIndex(idx);

            if (self.isSet(parent_idx)) {
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
    };
}
