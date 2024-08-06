const std = @import("std");
const cpu = @import("cpu.zig");

const log = std.log.scoped(.apic);

const ia32_apic_base_msr_addr = 0x1B;

fn isLapicSupported() bool {
    const cpuid = cpu.cpuid(0x1);
    return cpuid.edx & (1 << 9) != 0;
}

fn enableLapic() void {
    const lapic_base = cpu.rdmsr(ia32_apic_base_msr_addr);
    cpu.wrmsr(ia32_apic_base_msr_addr, lapic_base | (1 << 11));
}

pub fn init() !void {
    log.info("Initializing APIC", .{});
    defer log.info("APIC initialized", .{});

    const lapic_supported = isLapicSupported();
    log.info("Checking if LAPIC is supported: {}", .{lapic_supported});

    if (!lapic_supported) {
        return error.LAPICNotSupported;
    }

    enableLapic();
}
