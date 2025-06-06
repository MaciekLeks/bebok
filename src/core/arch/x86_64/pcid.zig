const max_pcid: u12 = 4095; // 12-bits

pub const Id = enum(u12) {
    // PCID=0 is reserved for kernel
    kernel = 0,
    // User PCIDs start from 1
    _,
};

var pcid_pool: [max_pcid + 1]bool = .{false} ** (max_pcid + 1);
var next_pcid: Id = 1; // PCID=0 is reserved for kernel

pub fn reserve() !Id {
    for (0..max_pcid) |_| {
        if (!pcid_pool[next_pcid]) {
            pcid_pool[next_pcid] = true;
            defer next_pcid = (next_pcid % max_pcid) + 1;
            return @enumFromInt(next_pcid);
        }
        next_pcid = (next_pcid % max_pcid) + 1;
    }
    return error.NoFreePCID;
}

pub fn release(cid: Id) void {
    pcid_pool[@intFromEnum(cid)] = false;
}
