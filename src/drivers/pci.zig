const std = @import("std");
const cpu = @import("../cpu.zig");

const t = std.testing;
const log = std.log.scoped(.pci);

const pci_config_addres_port = 0xCF8;
const pci_config_data_port = 0xCFC;

const RegisterOffset = enum(u8) {
    vendor_id = 0x00,
    device_id = 0x02,
    command = 0x04,
    status = 0x06,
    revision_id = 0x08,
    prog_if = 0x09,
    subclass = 0x0A,
    class_code = 0x0B,
    cache_line_size = 0x0C,
    latency_timer = 0x0D,
    header_type = 0x0E,
    bist = 0x0F,
    bar0 = 0x10,
    bar1 = 0x14,
    bar2 = 0x18,
    bar3 = 0x1C,
    bar4 = 0x20,
    bar5 = 0x24,
    cardbus_cis_pointer = 0x28,
    subsystem_vendor_id = 0x2C,
    subsystem_id = 0x2E,
    expansion_rom_base_address = 0x30,
    capabilities_pointer = 0x34,
    interrupt_line = 0x3C,
    interrupt_pin = 0x3D,
    min_grant = 0x3E,
    max_latency = 0x3F,
};

const PciConfigAddress = packed struct(u32) {
    register_offset: RegisterOffset, //0-7
    function_no: u3, //8-10
    slot_no: u5, //11-15 //physical device
    bus_no: u8, //16-23
    reserved: u7 = 0, //24-30
    enable: u1 = 1, //31
};

inline fn registerAddress(T: type, config_addr: PciConfigAddress) T {
    // Address must be aligned to 4 bytes, so we need to clear the last 2 bits cause we aligning down
    const mask: T = @alignOf(T) - 1;
    return @as(T, @bitCast(config_addr)) & ~mask;
}

test "PCI register addresses" {
    var config_addr = PciConfigAddress{
        .register_offset = .max_latency,
        .function_no = 0,
        .slot_no = 0,
        .bus_no = 0,
    };
    const x = registerAddress(u32, config_addr);
    log.warn("Register address: 0x{b:0>8}, 0x{b:0>8}", .{ x, @intFromEnum(RegisterOffset.max_latency) });
    //  try t.expect(registerAddress(u32, config_addr) == 0x80000000);

    config_addr = PciConfigAddress{
        .register_offset = .vendor_id,
        .function_no = 0,
        .slot_no = 0,
        .bus_no = 1,
    };
    try t.expect(registerAddress(u32, config_addr) == 0x80_01_00_00);

    config_addr = PciConfigAddress{
        .register_offset = .vendor_id,
        .function_no = 0,
        .slot_no = 1,
        .bus_no = 0,
    };
    try t.expect(registerAddress(u32, config_addr) == 0x80_00_08_00);

    config_addr = PciConfigAddress{
        .register_offset = .vendor_id,
        .function_no = 1,
        .slot_no = 0,
        .bus_no = 0,
    };
    try t.expect(registerAddress(u32, config_addr) == 0x80000100);
}

fn readRegister(
    T: type,
    config_addr: PciConfigAddress,
) T {
    cpu.out(u32, pci_config_addres_port, registerAddress(u32, config_addr));
    return cpu.in(T, pci_config_data_port);
}

fn checkBus(bus: u8) void {
    for (0..32) |slot| {
        checkSlot(bus, @intCast(slot));
    }
}

fn checkSlot(bus: u8, slot: u5) void {
    if (readRegister(u16, PciConfigAddress{
        .register_offset = .vendor_id,
        .function_no = 0,
        .slot_no = slot,
        .bus_no = bus,
    }) == 0xFFFF) {
        return;
    }

    checkFunction(bus, slot, 0);
    //const header_type = if (readRegister(u8, PciConfigAddress{
    _ = if (readRegister(u8, PciConfigAddress{
        .register_offset = .header_type,
        .function_no = 0,
        .slot_no = slot,
        .bus_no = bus,
    }) & 0x80 == 0) {
        return;
    };

    for (1..8) |function| {
        const function_no: u3 = @truncate(function);
        if (readRegister(u16, PciConfigAddress{
            .register_offset = .vendor_id,
            .function_no = function_no,
            .slot_no = slot,
            .bus_no = bus,
        }) != 0xFFFF) {
            checkFunction(bus, slot, function_no);
        }
    }
}

fn checkFunction(bus: u8, slot: u5, function: u3) void {
    const class_code = readRegister(u8, .{
        .register_offset = .class_code,
        .function_no = function,
        .slot_no = slot,
        .bus_no = bus,
    });

    const subclass = readRegister(u8, .{
        .register_offset = .subclass,
        .function_no = function,
        .slot_no = slot,
        .bus_no = bus,
    });

    if (class_code == 0x06 and subclass == 0x04) {
        // PCI-to-PCI bridge
        // TODO: implement
        log.warn("PCI-to-PCI bridge", .{});
    } else {
        log.warn("PCI device: bus: {d}, slot: {d}, function: {d}, class: {d}, subclass: {d}", .{
            bus,
            slot,
            function,
            class_code,
            subclass,
        });
    }
}

fn setRegisterOffset(config_addr: *PciConfigAddress, register_offset: RegisterOffset) *PciConfigAddress {
    config_addr.*.register_offset = register_offset;
    return config_addr;
}

pub fn init() void {
    log.info("Initializing PCI", .{});
    defer log.info("PCI initialized", .{});

    checkBus(0);
}
