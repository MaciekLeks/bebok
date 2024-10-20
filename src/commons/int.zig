// const std = @import("std");
//
// pub const InterruptPool = struct {
//     allocator: std.mem.Allocator,
//     used: std.bit_set.IntegerBitSet(256),
//
//     pub fn init(allocator: std.mem.Allocator) InterruptPool {
//         return .{
//             .allocator = allocator,
//             .used = std.bit_set.IntegerBitSet(256).initEmpty(),
//         };
//     }
//
//     pub fn acquireAny(self: *InterruptPool) ?u8 {
//         return self.used.findFirstUnset();
//     }
//
//     pub fn acquire(self: *InterruptPool, interrupt: u8) !u8 {
//         if (self.used.isSet(interrupt)) {
//             return error.InterruptAlreadyAcquired;
//         }
//         self.used.set(interrupt);
//         return interrupt;
//     }
//
//     pub fn markRangeAsUsed(self: *InterruptPool, start: u8, end: u8) !void {
//         if (start > end or end >= 256) {
//             return error.InvalidRange;
//         }
//
//         var i: u8 = start;
//         while (i <= end) : (i += 1) {
//             if (self.used.isSet(i)) {
//                 return error.InterruptAlreadyAcquired;
//             }
//         }
//
//         // If we get here, we know that the range is free
//         i = start;
//         while (i <= end) : (i += 1) {
//             self.used.set(i);
//         }
//     }
//
//     pub fn release(self: *InterruptPool, interrupt: u8) void {
//         self.used.unset(interrupt);
//     }
// };

const std = @import("std");

pub const InterruptPool = struct {
    used: u256 = 0,

    pub fn init() InterruptPool {
        return .{};
    }

    pub fn acquireAny(self: *InterruptPool) ?u8 {
        var i: u8 = 0;
        while (i < 256) : (i += 1) {
            if ((self.used & (@as(u256, 1) << i)) == 0) {
                self.used |= (@as(u256, 1) << i);
                return i;
            }
        }
        return null;
    }

    pub fn acquire(self: *InterruptPool, interrupt: u8) !u8 {
        if ((self.used & (@as(u256, 1) << interrupt)) != 0) {
            return error.InterruptAlreadyAcquired;
        }
        self.used |= (@as(u256, 1) << interrupt);
        return interrupt;
    }

    pub fn markRangeAsUsed(self: *InterruptPool, start: u8, end: u8) !void {
        if (start > end or end >= 256) {
            return error.InvalidRange;
        }

        var mask: u256 = 0;
        var i: u8 = start;
        while (i <= end) : (i += 1) {
            mask |= (@as(u256, 1) << i);
        }

        if ((self.used & mask) != 0) {
            return error.InterruptAlreadyAcquired;
        }

        self.used |= mask;
    }

    pub fn release(self: *InterruptPool, interrupt: u8) void {
        self.used &= ~(@as(u256, 1) << interrupt);
    }
};
