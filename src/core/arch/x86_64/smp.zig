const std = @import("std");
const cpu = @import("./cpu.zig");
const paging = @import("./paging.zig");
const limine = @import("limine");

const log = std.log.scoped(.smp);

pub export var smp_request: limine.SmpRequest = .{ .flags = 0 }; //flags: 1 -> X2APIC, 0 -> otherwise

var core_count: u64 = 0;

pub fn init() void {
    if (smp_request.response) |response| {
        log.info("SMP reponse: {}", .{response.*});
        core_count = response.cpu_count;
        for (0..core_count) |i| {
            log.info("CPUs Info: {}", .{response.cpus_ptr[i]});
        }
    }
}

pub fn cores() u64 {
    return core_count;
}
