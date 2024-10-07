const std = @import("std");
const builtin = @import("builtin");

const Device = @import("deps.zig").Device;
const Driver = @import("deps.zig").Driver;
const Registry = @import("deps.zig").Registry;
const cpu = @import("deps.zig").cpu;
const heap = @import("deps.zig").heap;
const paging = @import("deps.zig").paging;

const Bus = @import("bus.zig").Bus;
const NvmeDriver = @import("mod.zig").NvmeDriver;

const log = std.log.scoped(.pci);

const Pcie = @This();

pub usingnamespace switch (builtin.cpu.arch) {
    .x86_64 => @import("../arch/x86_64/pcie.zig"),
    else => |other| @compileError("Unimplemented for " ++ @tagName(other)),
};

const t = std.testing;
const ArrayList = std.ArrayList;

const native_endian = @import("builtin").target.cpu.arch.endian();
const assert = std.debug.assert;

const legacy_pci_config_addres_port = 0xCF8;
const legacy_pci_config_data_port = 0xCFC;

pub const PciError = error{
    CapabilitiesPointerNotFound,
    PciExpressCapabilityNotFound,
    MsiXCapabilityNotFound,
    DriverNotificationFailed,
};

pub const PcieAddress = struct {
    const Self = @This();
    bus: u8,
    slot: u5,
    function: u3,

    pub const Packed = packed struct {
        function: u3,
        slot: u5,
        bus: u8,

        pub fn unpack(self: Packed) Self {
            return .{ .bus = self.bus, .slot = self.slot, .function = self.function };
        }
    };

    pub fn pack(self: Self) Packed {
        return .{ .function = self.function, .slot = self.slot, .bus = self.bus };
    }
};

// Probe Context to match Device and Driver
pub const PcieProbeContext = struct {
    class_code: u8,
    subclass: u8,
    prog_if: u8,
};

//variables
var allctr: std.mem.Allocator = undefined;

//Fields
//drivers: DriverList,
base: *Bus,

// Inner Types
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
    capability_pointer = 0x34, //8 bits offset in the registry (most likely it's 0x40)
    interrupt_line = 0x3C,
    interrupt_pin = 0x3D,
    min_grant = 0x3E,
    max_latency = 0x3F,
};

const ConfigAddress = packed struct(u32) {
    // register_offset: RegisterOffset, //0-7
    register_offset: u8, //0-7 - can't use RegisterOffset because we are going to iterate over the cappabilities
    addr: PcieAddress.Packed,
    reserved: u7 = 0, //24-30
    enable: u1 = 1, //31
};

pub const Bar = struct {
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

pub const Command = packed struct(u16) {
    iose: bool, //I/O Space Enable
    mse: bool, //Memory Space Enable
    bme: bool, //Bus Master Enable
    sce: bool, //Special Cycle Enable
    mwie: bool, //Memory Write and Invalidate Enable
    vga: bool, //VGA Palette Snoop
    pee: bool, //Parity Error Response Enable
    rsvd_a: u1, //Reserved
    see: bool, //SERR# Enable
    fbe: bool, //Fast Back-to-Back Enable
    id: bool, //Interrupt Disable
    rsrvd_b: u5, //Reserved

};

pub const VersionCap = packed struct(u32) {
    cid: u8 = 0x10, //must be 0x01
    next: u8, //Next Capability Offset
    major: u8,
    minor: u8,
};

pub const MsiCap = packed struct(u192) {
    const MessageControl = packed struct(u16) {
        msie: bool,
        mmc: u3,
        mme: u3,
        c64: bool,
        pvm: bool,
        rsvd: u7,
    };
    cid: u8 = 0x05, //must be 0x05
    next: u8, //Next Capability Offset
    mc: MessageControl,
    ma: u32, //Message Address
    mua: u32, //Message Upper Address
    md: u16, //Message Data
    rsrv: u16,
    mask: u32,
    pending: u32,
};

pub const MsixCap = packed struct(u96) {
    const MessageControl = packed struct(u16) {
        ts: u11, //Table Size
        rsrvd: u3,
        fm: u1, //Function Mask
        mxe: bool, //MSI-X Enable
    };
    cid: u8 = 0x11, //must be 0x11
    next: u8, //Next Capability Offset
    mc: MessageControl,
    tbir: u3, //Table BIR
    to: u29, //Table Offset
    pbir: u3, //Pending Bit Array BIR
    pbao: u29, //Pending Bit Array Offset
};

pub const MsixTableEntry = extern struct {
    msg_addr: u64 align(1),
    msg_data: u32 align(1),
    vector_ctrl: u32 align(1),
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
        .addr = .{ .function = 0, .slot = 0, .bus = 0 },
    };
    const x = registerAddress(u32, config_addr);
    log.warn("Register address: 0x{b:0>8}, 0x{b:0>8}", .{ x, @intFromEnum(RegisterOffset.max_latency) });
    //  try t.expect(registerAddress(u32, config_addr) == 0x80000000);

    config_addr = ConfigAddress{
        .register_offset = .vendor_id,
        .addr = .{ .function = 0, .slot = 0, .bus = 1 },
    };
    try t.expect(registerAddress(u32, config_addr) == 0x80_01_00_00);

    config_addr = ConfigAddress{
        .register_offset = .vendor_id,
        .addr = .{ .function = 0, .slot = 1, .bus = 0 },
    };
    try t.expect(registerAddress(u32, config_addr) == 0x80_00_08_00);

    config_addr = ConfigAddress{ .register_offset = .vendor_id, .addr = .{ .function = 1, .slot = 0, .bus = 0 } };
    try t.expect(registerAddress(u32, config_addr) == 0x80000100);
}

fn readRegister(T: type, config_addr: ConfigAddress) T {
    cpu.out(u32, legacy_pci_config_addres_port, registerAddress(u32, config_addr));
    const config_data = blk: {
        var cd = cpu.in(T, @as(cpu.PortNumberType, legacy_pci_config_data_port) + (config_addr.register_offset & 0b11)); //use offset on the data config port
        if (native_endian == .big) {
            cd = @byteSwap(cd);
        }
        break :blk cd;
    };
    return config_data;
}

pub fn readRegisterWithArgs(T: type, register_offset: RegisterOffset, addr: PcieAddress) T {
    return readRegister(T, ConfigAddress{
        .register_offset = @intFromEnum(register_offset),
        .addr = addr.pack(),
    });
}

// With direct register offset
pub fn readRegisterWithRawArgs(T: type, raw_register_offset: u8, addr: PcieAddress) T {
    assert(raw_register_offset & 0b11 == 0);
    return readRegister(T, ConfigAddress{
        .register_offset = raw_register_offset,
        .addr = addr.pack(),
    });
}

fn writeRegister(T: type, config_addr: ConfigAddress, value: T) void {
    cpu.out(u32, legacy_pci_config_addres_port, registerAddress(u32, config_addr));
    if (native_endian == .big) {
        value = @byteSwap(value);
    }
    cpu.out(T, @as(cpu.PortNumberType, legacy_pci_config_data_port) + (config_addr.register_offset & 0b11), value);
}

pub fn writeRegisterWithArgs(T: type, register_offset: RegisterOffset, addr: PcieAddress, value: T) void {
    writeRegister(T, ConfigAddress{
        .register_offset = @intFromEnum(register_offset),
        .addr = addr.pack(),
    }, value);
}

pub fn writeRegisterWithRawArgs(T: type, raw_register_offset: u8, addr: PcieAddress, value: T) void {
    assert(raw_register_offset & 0b11 == 0);
    writeRegister(T, ConfigAddress{ .register_offset = raw_register_offset, .addr = addr.pack() }, value);
}

pub fn readBar(bar_addr: ConfigAddress) Bar {
    var bar: Bar = undefined;
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
                .register_offset = bar_addr.register_offset + @sizeOf(u32), //BAR[x + 1]
                .addr = bar_addr.addr,
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

pub fn readBarWithArgs(register_offset: RegisterOffset, addr: PcieAddress) Bar {
    return readBar(ConfigAddress{
        .register_offset = @intFromEnum(register_offset),
        .addr = addr.pack(),
    });
}

fn determineAddressSpaceSize(bar: Bar, bar_addr: ConfigAddress, bar_value: u32, next_bar_addr: ConfigAddress, next_bar_value: u32, is_a64: bool) u64 {
    //?const orig_command = readRegisterWithArgs(u16, .command, 0, bar_addr.slot_no, bar_addr.bus_no);
    const orig_command = readRegisterWithArgs(u16, .command, bar_addr.addr.unpack());
    const disable_command = orig_command & ~@as(u16, 0b11); //disable i/o space bit and memory space bit while getting the size
    writeRegisterWithArgs(u16, .command, bar_addr.addr.unpack(), disable_command);
    writeRegister(u32, bar_addr, 0xFFFF_FFFF);
    const bar_size_low = readRegister(u32, bar_addr);
    var bar_size_high: u32 = 0;
    writeRegister(u32, bar_addr, bar_value);
    if (is_a64) {
        writeRegister(u32, next_bar_addr, 0xFFFF_FFFF);
        bar_size_high = readRegister(u32, next_bar_addr);
        writeRegister(u32, next_bar_addr, next_bar_value);
    }
    writeRegisterWithArgs(u32, .command, bar_addr.addr.unpack(), orig_command);

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

fn checkBus(self: *Pcie, bus: u8) PciError!void {
    for (0..32) |slot| {
        try checkSlot(self, bus, @intCast(slot));
    }
}

fn checkSlot(self: *Pcie, bus: u8, slot: u5) PciError!void {
    if (readRegisterWithArgs(u16, .vendor_id, .{ .function = 0, .slot = slot, .bus = bus }) == 0xFFFF) {
        return;
    }
    try checkFunction(self, .{ .function = 0, .slot = slot, .bus = bus });
    _ = if (readRegisterWithArgs(u8, .header_type, .{ .function = 0, .slot = slot, .bus = bus }) & 0x80 == 0) {
        return;
    };
    for (1..8) |function| {
        const function_no: u3 = @truncate(function);
        const addr = .{ .function = function_no, .slot = slot, .bus = bus };
        if (readRegisterWithArgs(u16, .vendor_id, addr) != 0xFFFF) {
            try checkFunction(self, addr);
        }
    }
}

// Unique ID for a PCI device
pub fn uniqueId(addr: PcieAddress) u32 {
    return (@as(u32, addr.bus) << 16) | (@as(u32, addr.slot) << 8) | addr.function;
}

fn checkFunction(self: *Pcie, addr: PcieAddress) PciError!void {
    const class_code = readRegisterWithArgs(u8, .class_code, addr);
    const subclass = readRegisterWithArgs(u8, .subclass, addr);
    const prog_if = readRegisterWithArgs(u8, .prog_if, addr);
    const header_type = readRegisterWithArgs(u8, .header_type, addr);
    const vendor_id = readRegisterWithArgs(u16, .vendor_id, addr);
    const device_id = readRegisterWithArgs(u16, .device_id, addr);
    const interrupt_line = readRegisterWithArgs(u8, .interrupt_line, addr);
    const interrupt_pin = readRegisterWithArgs(u8, .interrupt_pin, addr);
    const command: Command = @bitCast(readRegisterWithArgs(u16, .command, addr));
    const status = readRegisterWithArgs(u16, .status, addr);
    const capabilities_pointer = readRegisterWithArgs(u8, .capability_pointer, addr);

    const bar = readBar(.{ .register_offset = @intFromEnum(RegisterOffset.bar0), .addr = addr.pack() });

    if (class_code == 0x06 and subclass == 0x04) {
        // PCI-to-PCI bridge
        log.debug("PCI-to-PCI bridge", .{});
        try checkBus(self, addr.bus + 1);
    } else {
        const size_KB = switch (bar.size) {
            .as32 => bar.size.as32 / 1024,
            .as64 => bar.size.as64 / 1024,
        };
        const size_MB = if (size_KB > 1024) size_KB / 1024 else 0;
        const size_GB = if (size_MB > 1024) size_MB / 1024 else 0;
        const phys = switch (bar.address) {
            .a32 => bar.address.a32,
            .a64 => bar.address.a64,
        };
        log.debug(
            \\PCI device: bus: {d}, 
            \\slot: {d}, 
            \\function: {d}, 
            \\class: {d}, 
            \\subclass: {d}, 
            \\prog_id: {d}, 
            \\header_type: 0x{x}, 
            \\vendor_id: 0x{x}, 
            \\device_id=0x{x}, 
            \\interrupt_no: 0x{x}, 
            \\interrupt_pin: 0x{x}, 
            \\bar: {}, 
            \\bar.addr: 0x{x}, 
            \\size: {d}GB, {d}MB, {d}KB, 
            \\command: {}, 
            \\status: 0b{b:0>16}",
            \\capabilities_pointer: 0x{x}, 
        , .{
            addr.bus,
            addr.slot,
            addr.function,
            class_code,
            subclass,
            prog_if,
            header_type,
            vendor_id,
            device_id,
            interrupt_line,
            interrupt_pin,
            bar,
            phys,
            size_GB,
            size_MB,
            size_KB,
            command,
            status, //bit 3 - Interrupt Status
            capabilities_pointer,
        });
    }

    probeAndSetupDevice(self, addr, class_code, subclass, prog_if) catch |err| {
        log.err("Error notifying driver: {}", .{err});
        return PciError.DriverNotificationFailed;
    };
}

pub fn registerDriver(self: *Pcie, driver: *const Driver) !void {
    try self.drivers.append(driver);
}

fn probeAndSetupDevice(self: *Pcie, addr: PcieAddress, class_code: u8, subclass: u8, prog_if: u8) !void {
    const drivers = self.base.registry.drivers;
    for (drivers.items) |drv| {
        if (drv.probe(&PcieProbeContext{ .class_code = class_code, .subclass = subclass, .prog_if = prog_if })) {
            const dev = try Device.init(allctr, .{ .pcie = addr });
            //let the driver fill the device struct
            try drv.setup(dev);
            try self.base.devices.append(dev);
        }
    }
}

pub fn deinit(self: *Pcie) void {
    log.info("Deinitializing PCI", .{});
    defer allctr.destroy(self);
    defer log.info("PCI deinitialized", .{});

    self.drivers.deinit();
}

pub fn init(allocator: std.mem.Allocator, bus: *Bus) !*Pcie {
    log.info("Initializing PCI", .{});
    defer log.info("PCI initialized", .{});
    var pcie = try allocator.create(Pcie);

    allctr = allocator;
    pcie.base = bus;

    return pcie;
}

pub fn destroy(self: *Pcie) void {
    defer self.base.destroy();
    self.drivers.deinit();
}

pub fn scan(self: *Pcie) PciError!void {
    log.info("Scanning PCI", .{});
    defer log.info("PCI scanned", .{});
    try checkBus(self, 0);
}

fn findCapabilityOffset(cap_id: u8, addr: PcieAddress) !u8 {
    const cap_offset = readRegisterWithArgs(u8, .capability_pointer, addr);
    if (cap_offset == 0) {
        return PciError.CapabilitiesPointerNotFound;
    }

    var cur_offset = cap_offset & 0xFC; //4 bits aligned
    var next_cap_offset: u8 = 0;
    while (cur_offset != 0) {
        const cap0x0 = readRegisterWithRawArgs(u32, cur_offset, addr);
        const read_cap_id: u8 = @truncate(cap0x0);
        if (read_cap_id == cap_id) {
            return cur_offset;
        }

        next_cap_offset = @truncate((cap0x0 >> 8) & 0xFF);
        cur_offset = next_cap_offset;
    }
    return error.PciExpressCapabilityNotFound;
}

pub fn readCapability(comptime TCap: type, addr: PcieAddress) !TCap {
    var val: TCap = undefined;

    const cap_id_field = std.meta.fieldInfo(TCap, .cid);
    const default_val_ptr = cap_id_field.default_value orelse @compileError("TCap.id must have a default value");
    const cap_id_ptr: *const u8 = @ptrCast(default_val_ptr);

    const cap_offset = try findCapabilityOffset(cap_id_ptr.*, addr);

    const val_size = @sizeOf(TCap);
    const reg_size = @sizeOf(u32);
    if (val_size % reg_size != 0) @compileError("TCap size must be a multiple of the u32 size");
    const reg_no = val_size / reg_size;

    const val_ptr: [*]u32 = @ptrCast(@alignCast(&val));
    inline for (0..reg_no) |i| {
        const reg_value = readRegisterWithRawArgs(u32, @intCast(cap_offset + i * reg_size), addr);
        //map the register to the struct
        val_ptr[i] = @bitCast(reg_value);
    }

    return val;
}

pub fn writeCapability(comptime TCap: type, val: TCap, addr: PcieAddress) !void {
    const cap_id_field = std.meta.fieldInfo(TCap, .cid);
    const default_val_ptr = cap_id_field.default_value orelse @compileError("TCap.id must have a default value");
    const cap_id_ptr: *const u8 = @ptrCast(default_val_ptr);

    const cap_offset = try findCapabilityOffset(cap_id_ptr.*, addr);

    const val_size = @sizeOf(TCap);
    const reg_size = @sizeOf(u32);
    if (val_size % reg_size != 0) @compileError("TCap size must be a multiple of the u32 size");
    const reg_no = val_size / reg_size;

    const val_ptr: [*]const u32 = @ptrCast(@alignCast(&val));
    inline for (0..reg_no) |i| {
        const reg_value = readRegisterWithRawArgs(u32, @intCast(cap_offset + i * reg_size), addr);
        //map the register to the struct
        if (reg_value != val_ptr[i]) {
            writeRegisterWithRawArgs(u32, @intCast(cap_offset + i * reg_size), addr, val_ptr[i]);
        }
    }
}

pub fn addMsixMessageTableEntry(msix_cap: MsixCap, bar: Bar, id: u11, vec_no: u8) void {
    assert(msix_cap.mc.ts > id);

    const virt = switch (bar.address) {
        inline else => |addr| paging.virtFromMME(addr),
    };

    const aligned_table_offset: u32 = msix_cap.to << 3;

    const msi_x_te: *volatile MsixTableEntry = @ptrFromInt(virt + aligned_table_offset + id * @sizeOf(MsixTableEntry));

    msi_x_te.* = .{
        //.msg_addr = paging.virtFromMME(@as(u32, @bitCast(Pcie.MsiMessageAddressRegister{
        //TODO Generealize it, now it's Intel specific
        .msg_addr = @as(u32, @bitCast(Pcie.MsiMessageAddressRegister{
            .destination_id = 0, //TODO promote to a parameter (CPUID)
            .rediration_hint = 0,
            .dest_mode = 0, //ignored
        })), //Remember, do not use virtual address here!
        .msg_data = @bitCast(Pcie.MsiMessageDataRegister{
            .vec_no = vec_no,
            .delivery_mode = .fixed,
            .trigger_mode = .edge,
            .level = 0,
        }),
        .vector_ctrl = 0,
    };

    //log iterates over all MsiXTableEntries
    const msix_entry_list: [*]volatile MsixTableEntry = @ptrFromInt(virt + aligned_table_offset);
    var i: u16 = 0;
    while (i < msix_cap.mc.ts) : (i += 1) {
        log.debug("MSI-X table entry[{d}]: addr: 0x{x}, msd_data: {}", .{ i, msix_entry_list[i].msg_addr, @as(Pcie.MsiMessageDataRegister, @bitCast(msix_entry_list[i].msg_data)) });
    }
    //logging ends

    //log.debug("MSI-X table entry added: {} @ {*}", .{ msi_x_te.*, msi_x_te });
}

// pub fn readMsixPendingBit(msix_cap: MsixCap, bar: BAR, id: u11) bool {
//     const virt = switch (bar.address) {
//         inline else => |addr| paging.virtFromMME(addr),
//     };
//     const aligned_pending_bit_offset: u32 = msix_cap.pbao << 3;
//
//     //pending bit array is an aray of bit values, e.g. id=9 means the 1st bit in the second byte
//     const byte_no = id / 8;
//     const bit_no: u3 = @intCast(id % 8);
//
//     //read the bit
//     const pending_bit = @as(*const u8, @ptrFromInt(virt + aligned_pending_bit_offset + byte_no));
//     return pending_bit.* & ((@as(u8, 1) << bit_no)) != 0;
// }
//
pub fn readMsixPendingBitArrayBit(msix_cap: MsixCap, bar: Bar, msix_table_idx: u11) u1 {
    const virt = switch (bar.address) {
        inline else => |addr| paging.virtFromMME(addr),
    };
    const aligned_pending_bit_offset: u32 = msix_cap.pbao << 3;
    // every bit under the PBA is a value of pending messgae in the Msix Table  (not interrupt vector number)
    const pending_bit: *volatile u1 = @as(*volatile u1, @ptrFromInt(virt + aligned_pending_bit_offset + msix_table_idx));
    log.debug("MSI-X pending bit: {}", .{pending_bit.*});
    return pending_bit.*;
}

pub fn writeMsixPendingBitArrayBit(msix_cap: MsixCap, bar: Bar, msix_table_idx: u11, value: u1) void {
    const virt = switch (bar.address) {
        inline else => |addr| paging.virtFromMME(addr),
    };
    const aligned_pending_bit_offset: u32 = msix_cap.pbao << 3;
    // every bit under the PBA is a value of pending messgae in the Msix Table  (not interrupt vector number)
    const pending_bit: *volatile u1 = @as(*volatile u1, @ptrFromInt(virt + aligned_pending_bit_offset + msix_table_idx));
    pending_bit.* = value;
    log.debug("MSI-X pending bit set: {}", .{pending_bit.*});
}
