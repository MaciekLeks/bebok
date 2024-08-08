const std = @import("std");
const cpu = @import("cpu.zig");
const paging = @import("paging.zig");
const limine = @import("smp.zig");

const log = std.log.scoped(.apic);

const apic_base_msr_addr: u32 = 0x1B;
var allocator: std.mem.Allocator = undefined;
const apic_registry_size: usize = 0x1000;
var apic_registry: []volatile u8 = undefined; //apic base is apic_regs.ptr

fn isLapicSupported() bool {
    const cpuid = cpu.cpuid(0x01);
    return cpuid.edx & (1 << 9) != 0;
}

fn enableLapic() void {
    var apic_base_msr: u64 = cpu.rdmsr(apic_base_msr_addr);
    log.info("Before updating APIC 0x1B@MSR: 0b{b:0>64}", .{apic_base_msr});

    apic_registry = allocator.alloc(u8, apic_registry_size) catch |err| {
        log.err("Failed to allocate memory for APIC registers: {}", .{err});
        return;
    };

    paging.adjustPageAreaPAT(@intFromPtr(apic_registry.ptr), apic_registry_size, .uncacheable) catch |err| {
        log.err("Failed to adjust page area PAT for APIC registry: {}", .{err});
        return;
    };
    log.info("APIC registry page area PAT set to UC", .{});

    const apic_registry_phys_addr = paging.physFromVirt(@intFromPtr(apic_registry.ptr)) catch |err| {
        log.err("Failed to get physical address of APIC registers: {}", .{err});
        return;
    };
    @memset(apic_registry, 0);

    log.info("Physical/Virtual address of APIC registers: 0x{x}/{*}", .{ apic_registry_phys_addr, apic_registry.ptr });

    // set APIC base address (bits 12 though 35 - 3 bytes) and enable APIC though bit 11 and Bootstrap Processor flag through bit 8
    //apic_base_msr |= ((0x0000_00FF_FFFF_F000 & apic_registry_phys_addr) << 12) | 1 << 11 | 1 << 8;
    apic_base_msr |= (0x0000_00FF_FFFF_F000 & apic_registry_phys_addr) | 1 << 11 | 1 << 8;
    log.info("Setting APIC MSR to 0x{x}", .{apic_base_msr});
    cpu.wrmsr(apic_base_msr_addr, apic_base_msr);

    apic_base_msr = cpu.rdmsr(apic_base_msr_addr);
    log.debug("Local APIC enabled 0x1B@MSR: 0x{0x}(0b{0b:0>64})", .{apic_base_msr});
}

const LapicRegisterOffset = enum(u10) {
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
    return @ptrCast(@alignCast(@as([*]volatile u8, apic_registry.ptr) + offset));
}

inline fn readRegister(T: type, offset: u10) align(128) T {
    return @volatileCast(registerAddr(T, offset)).*;
}

pub fn init(allocr: std.mem.Allocator) !void {
    log.info("Initializing APIC", .{});
    defer log.info("APIC initialized", .{});

    allocator = allocr;

    const lapic_supported = isLapicSupported();
    log.info("Checking if LAPIC is supported: {}", .{lapic_supported});

    if (!lapic_supported) {
        return error.LAPICNotSupported;
    }

    enableLapic();

    // Log all registers
    const fields = @typeInfo(LapicRegisterOffset).Enum.fields;
    inline for (fields, 0..) |field, i| {
        const val align(128) = readRegister(u16, field.value);
        log.info("Local APIC Register: name:{s} idx:{d}, value:0x{x}, value_ptr: 0x{*}", .{ field.name, i, val, &val });
    }

    // for (0..100) |i| {
    //     log.info("apic_registry[{d: >3}]:0x{x}", .{ i, apic_registry[i] });
    // }
}

pub fn deinit() void {
    log.info("Deinitializing APIC", .{});
    defer log.info("APIC deinitialized", .{});
    allocator.free(apic_registry);
}
