const std = @import("std");
const cpu = @import("../cpu.zig");
const heap = @import("../mem/heap.zig").heap;
//contollers
const Nvme = @import("./Nvme.zig");
//end of controllers

const t = std.testing;
const log = std.log.scoped(.pci);
const ArrayList = std.ArrayList;

const native_endian = @import("builtin").target.cpu.arch.endian();
const assert = std.debug.assert;

const pci_config_addres_port = 0xCF8;
const pci_config_data_port = 0xCFC;

pub const Driver = union(enum) {
    const Self = @This();
    nvme: *const Nvme,

    pub fn interested(self: Self, class_code: u8, subclass: u8, prog_if: u8) bool {
        return switch (self) {
            inline else => |it| it.interested(class_code, subclass, prog_if),
        };
    }

    pub fn update(self: Self, function_no: u3, slot_no: u5, bus_no: u8) void {
        return switch (self) {
            inline else => |it| it.update(function_no, slot_no, bus_no),
        };
    }
};

const DeviceList = ArrayList(*const Driver);

pub const RegisterOffset = enum(u8) {
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

pub const BAR = struct {
    prefetchable: bool, //TODO: change paging settings based on this
    address: union(enum) {
        a32: u32,
        a64: u64,
    },
    mmio: bool, //memory mapped i/o:  false => i/o space bar layout , true => i/o memory space bar layout
    size: union(enum) {
        as32: u32,
        as64: u64,
    },
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

pub fn readRegisterWithArgs(T: type, register_offset: RegisterOffset, function_no: u3, slot_no: u5, bus_no: u8) T {
    return readRegister(T, ConfigAddress{
        .register_offset = register_offset,
        .function_no = function_no,
        .slot_no = slot_no,
        .bus_no = bus_no,
    });
}

fn writeRegister(T: type, config_addr: ConfigAddress, value: T) void {
    cpu.out(u32, pci_config_addres_port, registerAddress(u32, config_addr));
    if (native_endian == .big) {
        value = @byteSwap(value);
    }
    cpu.out(T, @as(cpu.PortNumberType, pci_config_data_port) + (@intFromEnum(config_addr.register_offset) & 0b11), value);
}

pub fn writeRegisterWithArgs(T: type, register_offset: RegisterOffset, function_no: u3, slot_no: u5, bus_no: u8, value: T) void {
    writeRegister(T, ConfigAddress{
        .register_offset = register_offset,
        .function_no = function_no,
        .slot_no = slot_no,
        .bus_no = bus_no,
    }, value);
}

pub fn readBAR(bar_addr: ConfigAddress) BAR {
    var bar: BAR = undefined;
    const bar_value = readRegister(u32, bar_addr);

    var next_bar_value: u32 = undefined;
    var next_bar_addr: ConfigAddress = undefined;

    bar.mmio = bar_value & 0b1 == 0b0;
    const is_a64 = if (bar.mmio) bar_value & 0b110 == 0b100 else false;

    if (bar.mmio) {
        bar.prefetchable = bar_value & 0b100 == 0b100;
        if (!is_a64) {
            bar.address = .{ .a32 = bar_value & 0xFFFF_FFF0 };
        } else {
            next_bar_addr = .{
                .register_offset = @enumFromInt(@intFromEnum(bar_addr.register_offset) + @sizeOf(u32)),
                .function_no = bar_addr.function_no,
                .slot_no = bar_addr.slot_no,
                .bus_no = bar_addr.bus_no,
            };
            next_bar_value = readRegister(u32, next_bar_addr);
            bar.address = .{ .a64 = @as(u64, next_bar_value & 0xFFFF_FFFF) << 32 | bar_value & 0xFFFF_FFF0 };
        }
    } else {
        bar.address = .{ .a32 = bar_value & 0xFFFF_FFFC };
    }

    // determine the ammount of the address space
    const bar_size = determineAddressSpaceSize(bar, bar_addr, bar_value, next_bar_addr, next_bar_value, is_a64);

    switch (bar.mmio) {
        false => bar.size = .{ .as32 = @truncate(bar_size) },
        true => bar.size = switch (bar.address) {
            .a32 => .{ .as32 = @truncate(bar_size) },
            .a64 => .{ .as64 = bar_size },
        },
    }

    return bar;
}

pub fn readBARWithArgs(register_offset: RegisterOffset, function_no: u3, slot_no: u5, bus_no: u8) BAR {
    return readBAR(ConfigAddress{
        .register_offset = register_offset,
        .function_no = function_no,
        .slot_no = slot_no,
        .bus_no = bus_no,
    });
}

fn determineAddressSpaceSize(bar: BAR, bar_addr: ConfigAddress, bar_value: u32, next_bar_addr: ConfigAddress, next_bar_value: u32, is_a64: bool) u64 {
    const orig_command = readRegisterWithArgs(u16, .command, 0, bar_addr.slot_no, bar_addr.bus_no);
    const disable_command = orig_command & ~@as(u16, 0b11); //disable i/o space bit and memory space bit while getting the size
    writeRegisterWithArgs(u16, .command, bar_addr.function_no, bar_addr.slot_no, bar_addr.bus_no, disable_command);
    writeRegister(u32, bar_addr, 0xFFFF_FFFF);
    const bar_size_low = readRegister(u32, bar_addr);
    var bar_size_high: u32 = 0;
    writeRegister(u32, bar_addr, bar_value);
    if (is_a64) {
        writeRegister(u32, next_bar_addr, 0xFFFF_FFFF);
        bar_size_high = readRegister(u32, next_bar_addr);
        writeRegister(u32, next_bar_addr, next_bar_value);
    }
    writeRegisterWithArgs(u32, .command, bar_addr.function_no, bar_addr.slot_no, bar_addr.bus_no, orig_command);

    var bar_size: u64 = undefined;
    if (is_a64) {
        bar_size = @as(u64, bar_size_high) << @bitSizeOf(u32) | bar_size_low;
        // TODO: I'm not sure if this is correct for bar+1, should be also masked with 0xFFFF_FFF0_FFFF_FFF0?
        bar_size &= 0xFFFF_FFFF_FFFF_FFF0; //hide information bits
    } else {
        bar_size = bar_size_low;
        bar_size &= if (bar.mmio) 0xFFFF_FFF0 else 0xFFFF_FFFC; //hide information bits
    }
    bar_size = if (bar_size != 0) ~bar_size + 0x1 else 0; //invert and add 1

    return bar_size;
}

fn checkBus(bus: u8) void {
    for (0..32) |slot| {
        checkSlot(bus, @intCast(slot));
    }
}

fn checkSlot(bus: u8, slot: u5) void {
    if (readRegisterWithArgs(u16, .vendor_id, 0, slot, bus) == 0xFFFF) {
        return;
    }
    checkFunction(bus, slot, 0);
    _ = if (readRegisterWithArgs(u8, .header_type, 0, slot, bus) & 0x80 == 0) {
        return;
    };
    for (1..8) |function| {
        const function_no: u3 = @truncate(function);
        if (readRegisterWithArgs(u16, .vendor_id, function_no, slot, bus) != 0xFFFF) {
            checkFunction(bus, slot, function_no);
        }
    }
}

fn checkFunction(bus: u8, slot: u5, function: u3) void {
    const class_code = readRegisterWithArgs(u8, .class_code, function, slot, bus);
    const subclass = readRegisterWithArgs(u8, .subclass, function, slot, bus);
    const prog_if = readRegisterWithArgs(u8, .prog_if, function, slot, bus);
    const header_type = readRegisterWithArgs(u8, .header_type, function, slot, bus);
    const vendor_id = readRegisterWithArgs(u16, .vendor_id, function, slot, bus);
    const device_id = readRegisterWithArgs(u16, .device_id, function, slot, bus);
    const interrupt_line = readRegisterWithArgs(u8, .interrupt_line, function, slot, bus);
    const interrupt_pin = readRegisterWithArgs(u8, .interrupt_pin, function, slot, bus);
    const command = readRegisterWithArgs(u16, .command, function, slot, bus);

    const bar = readBAR(.{ .register_offset = .bar0, .function_no = function, .slot_no = slot, .bus_no = bus });

    if (class_code == 0x06 and subclass == 0x04) {
        // PCI-to-PCI bridge
        log.debug("PCI-to-PCI bridge", .{});
        checkBus(bus + 1);
    } else {
        const size_KB = switch (bar.size) {
            .as32 => bar.size.as32 / 1024,
            .as64 => bar.size.as64 / 1024,
        };
        const size_MB = if (size_KB > 1024) size_KB / 1024 else 0;
        const size_GB = if (size_MB > 1024) size_MB / 1024 else 0;
        const addr = switch (bar.address) {
            .a32 => bar.address.a32,
            .a64 => bar.address.a64,
        };
        log.debug("PCI device: bus: {d}, slot: {d}, function: {d}, class: {d}, subclass: {d}, prog_id: {d}, header_type: 0x{x}, vendor_id: 0x{x}, device_id=0x{x}, interrupt_no: 0x{x}, interrupt_pin: 0x{x}, bar: {}, bar.addr: 0x{x}, size: {d}GB, {d}MB, {d}KB, command: 0b{b:0>16}", .{
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
            bar,
            addr,
            size_GB,
            size_MB,
            size_KB,
            command,
        });
    }

    notifyDriver(function, slot, bus, class_code, subclass, prog_if);
}

var device_list: ?DeviceList = null;

pub fn registerDriver(driver: *const Driver) !void {
    assert(device_list != null);
    try device_list.?.append(driver);
}

fn notifyDriver(function: u3, slot: u5, bus: u8, class_code: u8, subclass: u8, prog_if: u8) void {
    assert(device_list != null);
    for (device_list.?.items) |d| {
        if (d.interested(class_code, subclass, prog_if)) {
            log.info("interested", .{});
            d.update(function, slot, bus);
        }
    }
}

pub fn deinit() void {
    log.info("Deinitializing PCI", .{});
    defer log.info("PCI deinitialized", .{});

    device_list.deinit();
}

pub fn init() void {
    log.info("Initializing PCI", .{});
    defer log.info("PCI initialized", .{});

    device_list = DeviceList.init(heap.page_allocator);
}

pub fn scan() void {
    checkBus(0);
}
