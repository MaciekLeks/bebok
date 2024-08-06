const std = @import("std");
const cpu = @import("cpu.zig");
const paging = @import("paging.zig");

const log = std.log.scoped(.apic);

const apic_base_msr_addr = 0x1B;
const apic_base_phys_addr: usize = 0xFEE00000;
var apic_base_virt_addr: usize = undefined;

fn isLocalAPICSupported() bool {
    const cpuid = cpu.cpuid(0x1);
    return cpuid.edx & (1 << 9) != 0;
}

fn enableLocalAPIC() void {
    const lapic_base = cpu.rdmsr(apic_base_msr_addr);
    cpu.wrmsr(apic_base_msr_addr, lapic_base | (1 << 11));
}

const LocalAPICRegisterOffset = enum(u10) {
    id = 0x20,
    version = 0x30,
    tpr = 0x80,
    eoi = 0xB0,
    sivr = 0xF0,
    lvt_timer = 0x320,
    lvt_thermal_sensor = 0x330,
    lvt_performance_monitor = 0x340,
    lvt_lint0 = 0x350,
    lvt_lint1 = 0x360,
    lvt_error = 0x370,
    timer_initial_count = 0x380,
    timer_current_count = 0x390,
    timer_divide_config = 0x3E0,
};

inline fn registerAddr(T: type, offset: u10) *volatile T {
    return @ptrFromInt(apic_base_virt_addr + offset);
}

inline fn readRegister(T: type, offset: u10) align(128) T {
    return @volatileCast(registerAddr(T, offset)).*;
}

pub fn init() !void {
    log.info("Initializing APIC", .{});
    defer log.info("APIC initialized", .{});

    const lapic_supported = isLocalAPICSupported();
    log.info("Checking if LAPIC is supported: {}", .{lapic_supported});

    if (!lapic_supported) {
        return error.LAPICNotSupported;
    }

    enableLocalAPIC();

    apic_base_virt_addr = paging.virtFromMME(apic_base_phys_addr);
    log.info("Virtual address of APIC: 0x{x}", .{apic_base_virt_addr});

    // Log all registers
    const fields = @typeInfo(LocalAPICRegisterOffset).Enum.fields;
    inline for (fields, 0..) |field, i| {
        const val align(128) = readRegister(u32, field.value);
        log.info("Local APIC Register: name:{s} idx:{d}, value:0x{x}, value_ptr: 0x{*}", .{ field.name, i, val, &val });
    }
}
