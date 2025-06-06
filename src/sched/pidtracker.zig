const std = @import("std");
const config = @import("config");

const Self = @This();

//Types
pub const Pid = enum(u32) {
    unassigned = 0,
    _,
};

//Fields
var bitset = std.bit_set.StaticBitSet(config.max_pid).initEmpty();
var cursor: u32 = 0; // used to track the next PID to allocate

pub fn getNextPid() !Pid {
    //const start = @as(u32, @intCast((self.cursor + 1) % config.max_pid));
    const start: u32 = (cursor + 1) % config.max_pid;
    var i = start;

    while (true) {
        if (!bitset.isSet(i)) {
            bitset.set(i);
            cursor = i;
            // Convert index to Pid (index 0 → PID 1)
            return @enumFromInt(i + 1);
        }
        i = (i + 1) % config.max_pid;
        if (i == start) break;
    }
    return error.NoFreePid;
}

pub fn releasePid(pid: Pid) void {
    const value = @intFromEnum(pid);
    if (value == 0) return; // Ignoruj .unassigned
    const index = value - 1; // PID 1 → indeks 0
    bitset.unset(index);
}
