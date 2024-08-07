const std = @import("std");
const cpu = @import("cpu.zig");
const paging = @import("paging.zig");

const log = std.log.scoped(.apic);

const apic_base_msr: u32 = 0x1B;
const apic_base_phys_addr: usize = 0xFEE00000;
var apic_base_virt_addr: usize = undefined;
var allocator: std.mem.Allocator = undefined;
const apic_registry_size: usize = 0x1000;
var apic_regs: []u8 = undefined;

fn isLocalAPICSupported() bool {
    const cpuid = cpu.cpuid(0x01);
    return cpuid.edx & (1 << 9) != 0;
}

fn enableLocalAPIC() void {
    var lapic_base: u64 = cpu.rdmsr(apic_base_msr);
    log.info("Local APIC enabled: 0b{b:0>64}", .{lapic_base});

    apic_regs = allocator.alloc(u8, apic_registry_size) catch |err| {
        log.err("Failed to allocate memory for APIC registers: {}", .{err});
        return;
    };

    const apic_regs_phys = paging.physFromVirt(@intFromPtr(apic_regs.ptr)) catch |err| {
        log.err("Failed to get physical address of APIC registers: {}", .{err});
        return;
    };
    @memset(apic_regs, 0);

    log.info("Physical address of APIC registers: 0x{x}", .{apic_regs_phys});

    // set APIC base address (bits 12 though 35) and enable APIC though bit 11
    lapic_base |= ((0x0000_00FF_FFFF_F000 & apic_regs_phys) << 12) | 1 << 11;
    cpu.wrmsr(apic_base_msr, lapic_base);

    lapic_base = cpu.rdmsr(apic_base_msr);
    log.info("Local APIC enabled: 0x{0x}(0b{0b:0>64})", .{lapic_base});
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

pub fn init(allocr: std.mem.Allocator) !void {
    log.info("Initializing APIC", .{});
    defer log.info("APIC initialized", .{});

    allocator = allocr;

    const lapic_supported = isLocalAPICSupported();
    log.info("Checking if LAPIC is supported: {}", .{lapic_supported});

    if (!lapic_supported) {
        return error.LAPICNotSupported;
    }

    enableLocalAPIC();

    // Log all registers
    const fields = @typeInfo(LocalAPICRegisterOffset).Enum.fields;
    inline for (fields, 0..) |field, i| {
        const val align(128) = readRegister(u32, field.value);
        log.info("Local APIC Register: name:{s} idx:{d}, value:0x{x}, value_ptr: 0x{*}", .{ field.name, i, val, &val });
    }
}

pub fn deinit() void {
    log.info("Deinitializing APIC", .{});
    defer log.info("APIC deinitialized", .{});
    allocator.free(apic_regs);
}
