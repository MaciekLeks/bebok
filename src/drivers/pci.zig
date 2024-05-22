const std = @import("std");
const cpu = @import("../cpu.zig");
const t = std.testing;
const log = std.log.scoped(.pci);

const native_endian = @import("builtin").target.cpu.arch.endian();
const assert = std.debug.assert;

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

const ConfigAddress = packed struct(u32) {
    register_offset: RegisterOffset, //0-7
    function_no: u3, //8-10
    slot_no: u5, //11-15 //physical device
    bus_no: u8, //16-23
    reserved: u7 = 0, //24-30
    enable: u1 = 1, //31
};

// const AdressType = {
//     .x64,
//     .x32,
// };

const BAR = struct {
    prefetchable: bool, //TODO: change paging settings based on this
    address: union(enum) {
        a32: u32,
        a64: u64,
    },
    mmio: bool, //memory mapped i/o:  false => i/o space bar layout , true => i/o memory space bar layout
    size: u32,
};

const ConfigData = u32;

inline fn registerAddress(T: type, config_addr: ConfigAddress) T {
    // Address must be aligned to 4 bytes, so we need to clear the last 2 bits cause we aligning down
    const mask: T = @alignOf(T) - 1;
    return @as(T, @bitCast(config_addr)) & ~mask;
}

test "PCI register addresses" {
    var config_addr = ConfigAddress{
        .register_offset = .max_latency,
        .function_no = 0,
        .slot_no = 0,
        .bus_no = 0,
    };
    const x = registerAddress(u32, config_addr);
    log.warn("Register address: 0x{b:0>8}, 0x{b:0>8}", .{ x, @intFromEnum(RegisterOffset.max_latency) });
    //  try t.expect(registerAddress(u32, config_addr) == 0x80000000);

    config_addr = ConfigAddress{
        .register_offset = .vendor_id,
        .function_no = 0,
        .slot_no = 0,
        .bus_no = 1,
    };
    try t.expect(registerAddress(u32, config_addr) == 0x80_01_00_00);

    config_addr = ConfigAddress{
        .register_offset = .vendor_id,
        .function_no = 0,
        .slot_no = 1,
        .bus_no = 0,
    };
    try t.expect(registerAddress(u32, config_addr) == 0x80_00_08_00);

    config_addr = ConfigAddress{
        .register_offset = .vendor_id,
        .function_no = 1,
        .slot_no = 0,
        .bus_no = 0,
    };
    try t.expect(registerAddress(u32, config_addr) == 0x80000100);
}

fn readRegister(T: type, config_addr: ConfigAddress) T {
    cpu.out(u32, pci_config_addres_port, registerAddress(u32, config_addr));
    const config_data = blk: {
        var cd = cpu.in(T, @as(cpu.PortNumberType, pci_config_data_port) + (@intFromEnum(config_addr.register_offset) & 0b11)); //use offset on the data config port
        if (native_endian == .big) {
            cd = @byteSwap(cd);
        }
        break :blk cd;
    };
    return config_data;
}

fn writeRegister(T: type, config_addr: ConfigAddress, value: T) void {
    cpu.out(u32, pci_config_addres_port, registerAddress(u32, config_addr));
    if (native_endian == .big) {
        value = @byteSwap(value);
    }
    cpu.out(T, @as(cpu.PortNumberType, pci_config_data_port) + (@intFromEnum(config_addr.register_offset) & 0b11), value);
}

fn readBAR(config_addr: ConfigAddress) BAR {
    var bar: BAR = undefined;
    const bar_value = readRegister(u32, config_addr);

    var next_bar_value: u32 = undefined;
    var next_bar_addr: ConfigAddress = undefined;

    bar.mmio = bar_value & 0b1 == 0b0;
    const is_a64 = if (bar.mmio) bar_value & 0b10 == 0b10 else false;

    if (bar.mmio) {
        bar.prefetchable = bar_value & 0b100 == 0b100;
        if (!is_a64) {
            bar.address = .{ .a32 = bar_value & 0xFFFF_FFF0 };
        } else {
            next_bar_addr = config_addr;
            next_bar_value = readRegister(u32, setRegisterOffset(&next_bar_addr, @enumFromInt(@intFromEnum(config_addr.register_offset) + @sizeOf(u32))).*);
            bar.address = .{ .a64 = @as(u64, next_bar_value & 0xFFFFFFFF) << 32 | bar_value & 0xFFFF_FFF0 };
        }
    } else {
        bar.address = .{ .a32 = bar_value & 0xFFFF_FFFC };
    }

    //determine the ammount of the address space
    // TODO: only with barN not barN+1 in case of 64 bit - is it OK? - check the spec, meanwile it works u64 size code is commented out
    var command_addr = config_addr; //copy the config address
    _ = setRegisterOffset(&command_addr, .command); //change register offset to command
    const orig_command = readRegister(u16, command_addr);
    const disable_command = orig_command & ~@as(u16, 0b11);
    writeRegister(u16, command_addr, disable_command);

    writeRegister(u32, config_addr, 0xFFFFFFFF);
    const bar_size_low = readRegister(u32, config_addr);
    // var bar_size_high: u32 = 0;
    // writeRegister(u32, config_addr, bar_value);
    // if (is_a64) {
    //     writeRegister(u32, next_bar_addr, 0xFFFFFFFF);
    //     bar_size_high = readRegister(u32, next_bar_addr);
    //     writeRegister(u32, next_bar_addr, next_bar_value);
    // }
    writeRegister(u32, command_addr, orig_command);

    //var bar_size = bar_size_low |  @as(u64, bar_size_high << @sizeOf(u32));
    var bar_size = bar_size_low;
    bar_size &= if (bar.mmio) 0xFFFF_FFF0 else 0xFFFF_FFFC; //hide information bits
    bar_size = @addWithOverflow(~bar_size, 0x1)[0]; //overflow if bar_size == 0
    // end of determining the ammount of the address space

    //if (bar_size > 0xFFFF_FFFF) @panic("BAR size is too big");
    //bar.size = @intCast(bar_size);
    bar.size = bar_size;

    return bar;
}

fn checkBus(bus: u8) void {
    for (0..32) |slot| {
        checkSlot(bus, @intCast(slot));
    }
}

fn checkSlot(bus: u8, slot: u5) void {
    if (readRegister(u16, ConfigAddress{
        .register_offset = .vendor_id,
        .function_no = 0,
        .slot_no = slot,
        .bus_no = bus,
    }) == 0xFFFF) {
        return;
    }

    checkFunction(bus, slot, 0);
    //const header_type = if (readRegister(u8, PciConfigAddress{
    _ = if (readRegister(u8, ConfigAddress{
        .register_offset = .header_type,
        .function_no = 0,
        .slot_no = slot,
        .bus_no = bus,
    }) & 0x80 == 0) {
        return;
    };

    for (1..8) |function| {
        const function_no: u3 = @truncate(function);
        if (readRegister(u16, ConfigAddress{
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

    const prog_if = readRegister(u8, .{
        .register_offset = .prog_if,
        .function_no = function,
        .slot_no = slot,
        .bus_no = bus,
    });

    //TODO: remove this
    const header_type = readRegister(u8, .{
        .register_offset = .header_type,
        .function_no = function,
        .slot_no = slot,
        .bus_no = bus,
    });

    //TODO remove this
    const vendor_id = readRegister(u16, .{
        .register_offset = .vendor_id,
        .function_no = function,
        .slot_no = slot,
        .bus_no = bus,
    });

    //TODO remove this
    const device_id = readRegister(u16, .{
        .register_offset = .device_id,
        .function_no = function,
        .slot_no = slot,
        .bus_no = bus,
    });

    //TODO remove this
    const interrupt_line = readRegister(u8, .{
        .register_offset = .interrupt_line,
        .function_no = function,
        .slot_no = slot,
        .bus_no = bus,
    });

    // TODO remove this
    const interrupt_pin = readRegister(u8, .{
        .register_offset = .interrupt_pin,
        .function_no = function,
        .slot_no = slot,
        .bus_no = bus,
    });

    //TODO remove this
    const bar0 = readBAR(.{ .register_offset = .bar0, .function_no = function, .slot_no = slot, .bus_no = bus });

    //TODO: remove this
    const command = readRegister(u16, .{
        .register_offset = .command,
        .function_no = function,
        .slot_no = slot,
        .bus_no = bus,
    });

    if (class_code == 0x06 and subclass == 0x04) {
        // PCI-to-PCI bridge
        log.warn("PCI-to-PCI bridge", .{});
        checkBus(bus + 1);
    } else {
        log.info("PCI device: bus: {d}, slot: {d}, function: {d}, class: {d}, subclass: {d}, prog_id: {d}, header_type: 0x{x}, vendor_id: 0x{x}, device_id=0x{x}, interrupt_no: 0x{x}, interrupt_pin: 0x{x}, bar0: {}, command: 0b{b:0>16}", .{
            bus,
            slot,
            function,
            class_code,
            subclass,
            prog_if,
            header_type,
            vendor_id,
            device_id,
            interrupt_line,
            interrupt_pin,
            bar0,
            command,
        });
    }
}

fn setRegisterOffset(config_addr: *ConfigAddress, register_offset: RegisterOffset) *ConfigAddress {
    config_addr.*.register_offset = register_offset;
    return config_addr;
}

pub fn init() void {
    log.info("Initializing PCI", .{});
    defer log.info("PCI initialized", .{});

    checkBus(0);
}
