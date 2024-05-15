const std = @import("std");
const cpu = @import("../cpu.zig");

const t = std.testing;
const log = std.log.scoped(.pci);

const pci_config_addres = 0xCF8;
const pci_config_data = 0xCFC;

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

inline fn registerAddress(config_addr: PciConfigAddress) align(@alignOf(u32)) u32 {
    return @bitCast(config_addr);
}

test  "PCI register addresses" {
    var config_addr = PciConfigAddress{
        .register_offset = .vendor_id,
        .function_no = 0,
        .slot_no = 0,
        .bus_no = 0,
    };
    try t.expect(registerAddress(config_addr) == 0x80000000);

    config_addr = PciConfigAddress{
        .register_offset = .vendor_id,
        .function_no = 0,
        .slot_no = 0,
        .bus_no = 1,
    };
    try  t.expect(registerAddress(config_addr) == 0x80_01_00_00);

    config_addr = PciConfigAddress{
        .register_offset = .vendor_id,
        .function_no = 0,
        .slot_no = 1,
        .bus_no = 0,
    };
    try t.expect(registerAddress(config_addr) == 0x80_00_08_00);

    config_addr = PciConfigAddress{
        .register_offset = .vendor_id,
        .function_no = 1,
        .slot_no = 0,
        .bus_no = 0,
    };
    try t.expect(registerAddress(config_addr) == 0x80000100);
}

fn readConfig(config_addr: PciConfigAddress) PciConfigData {
    cpu.out(u32, pci_config_addres, registerAddress(config_addr));
    return PciConfigData{ .data = cpu.in(u32, pci_config_data) };
}

pub fn init() void {
    log.info("Initializing PCI");


    defer log.info("PCI initialized");
}