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
    slot_no: u5,  //11-15 //physical device
    bus_no: u8,     //16-23
    reserved: u7 = 0, //24-30
    enable: u1 = 1, //31
};

const PciConfigData = packed struct(u32) {
    data: u32,
};

inline fn registerAddress(T: type, config_addr: PciConfigAddress) T {
    // Address must be aligned to 4 bytes, so we need to clear the last 2 bits cause we aligning down
    const mask : T = @alignOf(T) - 1;
    return @as(T, @bitCast(config_addr))  & ~mask;
}

test  "PCI register addresses" {
    var config_addr = PciConfigAddress{
        .register_offset = .max_latency,
        .function_no = 0,
        .slot_no = 0,
        .bus_no = 0,
    };
    const x = registerAddress(u32, config_addr);
    log.warn("Register address: 0x{b:0>8}, 0x{b:0>8}", .{x, @intFromEnum(RegisterOffset.max_latency)});
  //  try t.expect(registerAddress(u32, config_addr) == 0x80000000);

    config_addr = PciConfigAddress{
        .register_offset = .vendor_id,
        .function_no = 0,
        .slot_no = 0,
        .bus_no = 1,
    };
    try  t.expect(registerAddress(u32, config_addr) == 0x80_01_00_00);

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

fn readRegister(T: type, pci_config_addres: PciConfigAddress, register_offset: RegisterOffset) T {
    const config_data = readConfig(pci_config_addres);
    const offset : u32 = @intFromEnum(register_offset);
    return @as(T, @bitCast(config_data.data >> offset));
}

fn readConfig(config_addr: PciConfigAddress) PciConfigData {
    cpu.out(u32, pci_config_addres_port, registerAddress(config_addr));
    return PciConfigData{ .data = cpu.in(u32, pci_config_data_port) };
}

pub fn init() void {
    log.info("Initializing PCI");


    defer log.info("PCI initialized");
}