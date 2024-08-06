const std = @import("std");
const cpu = @import("cpu.zig");

const log = std.log.scoped(.apic);

fn lapicSupported() bool {
    const cpuid = cpu.cpuid(0x1);
    return cpuid.edx & (1 << 9) != 0;
}

pub fn init() !void {
    log.info("Initializing APIC", .{});
    defer log.info("APIC initialized", .{});

    const lapic_supported = lapicSupported();
    log.info("Checking if LAPIC is supported: {}", .{lapic_supported});

    if (!lapic_supported) {
        return error.LAPICNotSupported;
    }
}
