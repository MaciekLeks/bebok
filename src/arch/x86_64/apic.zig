const std = @import("std");
const cpu = @import("cpu.zig");
const paging = @import("paging.zig");
const limine = @import("smp.zig");

const log = std.log.scoped(.apic);

const apic_base_msr_addr: u32 = 0x1B;
//var allocator: std.mem.Allocator = undefined;
const apic_registry_size: usize = 0x1000;
var apic_default_base_phys: usize = undefined;
var apic_default_base_virt: usize = undefined;
const lvt_mask = 0x10000;

fn isLapicSupported(cpuid: u16) bool {
    const cpuid_res = cpu.cpuid(cpuid);
    return cpuid_res.edx & (1 << 9) != 0;
}

// only on Pentium 4, Intel Xeon, Intel P6 processors
// fn enableLapic() void {
//     var apic_base_msr: u64 = cpu.rdmsr(apic_base_msr_addr);
//     log.info("Before updating APIC 0x1B@MSR: 0b{b:0>64}", .{apic_base_msr});
//
//     apic_registry = allocator.alloc(u8, apic_registry_size) catch |err| {
//         log.err("Failed to allocate memory for APIC registers: {}", .{err});
//         return;
//     };
//
//     paging.adjustPageAreaPAT(@intFromPtr(apic_registry.ptr), apic_registry_size, .uncacheable) catch |err| {
//         log.err("Failed to adjust page area PAT for APIC registry: {}", .{err});
//         return;
//     };
//     log.info("APIC registry page area PAT set to UC", .{});
//
//     const apic_registry_phys_addr = paging.physFromVirt(@intFromPtr(apic_registry.ptr)) catch |err| {
//         log.err("Failed to get physical address of APIC registers: {}", .{err});
//         return;
//     };
//     @memset(apic_registry, 0);
//
//     log.info("Physical/Virtual address of APIC registers: 0x{x}/{*}", .{ apic_registry_phys_addr, apic_registry.ptr });
//
//     // set APIC base address (bits 12 though 35 - 3 bytes) and enable APIC though bit 11 and Bootstrap Processor flag through bit 8
//     //apic_base_msr |= ((0x0000_00FF_FFFF_F000 & apic_registry_phys_addr) << 12) | 1 << 11 | 1 << 8;
//     apic_base_msr |= (0x0000_00FF_FFFF_F000 & apic_registry_phys_addr) | 1 << 11 | 1 << 8;
//     log.info("Setting APIC MSR to 0x{x}", .{apic_base_msr});
//     cpu.wrmsr(apic_base_msr_addr, apic_base_msr);
//
//     apic_base_msr = cpu.rdmsr(apic_base_msr_addr);
//     log.debug("Local APIC enabled 0x1B@MSR: 0x{0x}(0b{0b:0>64})", .{apic_base_msr});
// }
//
fn enableLapicWithDefaultBase() void {
    var apic_base_msr: u64 = cpu.rdmsr(apic_base_msr_addr);
    log.info("Before updating APIC 0x1B@MSR: 0b{0b:0>64}=0x{0x} ", .{apic_base_msr});

    apic_default_base_phys = 0x0000_00FF_FFFF_F000 & apic_base_msr;

    apic_default_base_virt = paging.virtFromMME(apic_default_base_phys);
    log.info("APIC default base virtual address: 0x{x}", .{apic_default_base_virt});

    paging.adjustPageAreaPAT(apic_default_base_virt, apic_registry_size, .uncacheable) catch |err| {
        log.err("Failed to adjust page area PAT for APIC registry: {}", .{err});
        return;
    };
    log.info("APIC registry page area PAT set to UC", .{});

    // set APIC base address (bits 12 though 35 - 3 bytes) and enable Local APIC though bit 11 and Bootstrap Processor flag through bit 8
    if (apic_base_msr & 1 << 11 == 0) {
        apic_base_msr |= 1 << 11;
        log.info("Setting APIC MSR to 0x{x}", .{apic_base_msr});
        cpu.wrmsr(apic_base_msr_addr, apic_base_msr);

        apic_base_msr = cpu.rdmsr(apic_base_msr_addr);
    }

    log.debug("Local APIC enabled 0x1B@MS0x{0x}(0b{0b:0>64})", .{apic_base_msr});
}

const LapicRegisterOffset = enum(u10) {
    id = 0x20,
    version = 0x30,
    tpr = 0x80,
    eoi = 0xB0,
    ldr = 0xD0,
    sivr = 0xF0,
    isr0 = 0x100,
    isr1 = 0x110,
    isr2 = 0x120,
    isr3 = 0x130,
    isr4 = 0x140,
    isr5 = 0x150,
    isr6 = 0x160,
    isr7 = 0x170,
    tmr0 = 0x180,
    tmr1 = 0x190,
    tmr2 = 0x1A0,
    tmr3 = 0x1B0,
    tmr4 = 0x1C0,
    tmr5 = 0x1D0,
    tmr6 = 0x1E0,
    tmr7 = 0x1F0,
    irr0 = 0x200,
    irr1 = 0x210,
    irr2 = 0x220,
    irr3 = 0x230,
    irr4 = 0x240,
    irr5 = 0x250,
    irr6 = 0x260,
    irr7 = 0x270,
    esr = 0x280,
    icr0 = 0x300,
    icr1 = 0x310,
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

inline fn registerAddr(T: type, offset: LapicRegisterOffset) *align(16) volatile T {
    return @ptrFromInt(apic_default_base_virt + @intFromEnum(offset));
}

inline fn readRegister(T: type, offset: LapicRegisterOffset) align(16) T {
    return @volatileCast(registerAddr(T, offset)).*;
}

inline fn writeRegister(T: type, offset: LapicRegisterOffset, val: T) void {
    const aligned_val align(16) = val;
    registerAddr(T, offset).* = aligned_val;
}

pub fn logRegistryState() void {
    // Log all registers
    const fields = @typeInfo(LapicRegisterOffset).@"enum".fields;
    log.info("Local APIC Register State", .{});
    inline for (fields) |field| {
        const val align(16) = readRegister(u32, @enumFromInt(field.value));
        log.info("Local APIC Register: {s} -> value:0x{x} at 0x{*}", .{ field.name, val, &val });
    }
}

pub fn init() !void {
    log.info("Initializing APIC", .{});
    defer log.info("APIC initialized", .{});

    const lapic_supported = isLapicSupported(0);
    log.info("Checking if LAPIC is supported: {}", .{lapic_supported});

    if (!lapic_supported) {
        return error.LAPICNotSupported;
    }

    enableLapicWithDefaultBase();

    logRegistryState();

    // Enable Local APIC by setting the Spurious Interrupt Vector Register
    writeRegister(u32, .sivr, readRegister(u32, .sivr) | 0x100); // Enable Local APIC

    // Disable LVT entries for LINT0 and LINT1
    writeRegister(u32, .lvt_lint0, lvt_mask); // Mask
    writeRegister(u32, .lvt_lint1, lvt_mask); // Mask

    // Disable LVT Timer, and LVT Thermal Sensor
    writeRegister(u32, .lvt_timer, lvt_mask); // Mask
    writeRegister(u32, .lvt_thermal_sensor, lvt_mask); //Mask

    // Set up the LVT Error
    writeRegister(u32, .lvt_error, lvt_mask); //Mask

    // Initialize the timer
    writeRegister(u32, .timer_divide_config, 0x3); //divide by 16, see Figure 11.10 in the Intel System Programming Guide
    writeRegister(u32, .timer_initial_count, 0);

    logRegistryState();

    // TODO: tbd - set timer test
    setTimerTest();
    logRegistryState();

    const id align(16) = readRegister(u32, .id);
    log.info("Local APIC ID: 0x{x}, align:{d}", .{ id, @alignOf(@TypeOf(id)) });
}

// --- helper functions ---
pub fn ack() void {
    writeRegister(u32, .eoi, 0);
}

pub fn setTimerTest() void {
    // Initialize the timer
    log.info("Setting up the timer", .{});
    writeRegister(u32, .timer_divide_config, 0x0011); //divide by 16 (2nd bit is always 0), see Figure 11.10 in the Intel System Programming Guide
    writeRegister(u32, .timer_initial_count, 0x10000);
    writeRegister(u32, .lvt_timer, 0x00 << 17 | 0x30); //0x01 - periodic - 17-18 bits,  we do not use 0x20 for PIC even it's masked

}
