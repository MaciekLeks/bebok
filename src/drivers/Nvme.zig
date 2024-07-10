const std = @import("std");
const log = std.log.scoped(.nvme);
const pci = @import("pci.zig");
const paging = @import("../paging.zig");
const int = @import("../int.zig");

const nvme_class_code = 0x01;
const nvme_subclass = 0x08;
const nvme_prog_if = 0x02;

const Self = @This();

const CSSField = packed struct(u8) {
    nvmcs: u1, //0 NVM Command Set or Discovery Controller
    rsrvd: u5, //1-5
    iocs: u1, //6 I/O Command Set
    acs: u1, //7 Admin Command Set only
};

const CAPRegister = packed struct(u64) {
    mqes: u16, //0-15
    cqr: u1, //16
    ams: u2, //17-18
    rsrvd_a: u5, //19-23
    to: u8, //24-31
    dstrd: u4, //32-35
    nsqr: u1, //36-36
    css: CSSField, //37-44
    bsp: u1, //45
    cps: u2, //46-47
    mpsmin: u4, //48-51
    mpsmax: u4, //52-55
    pmrs: u1, //56
    cmbs: u1, //57
    nsss: u1, //58
    crms: u2, //59-60
    rsrvd_b: u3, //61-63
};

const CCRegister = packed struct(u32) {
    en: u1, //0 use to reset the controller
    rsrvd_a: u3, //1-3
    css: u3, //4-6
    mps: u4, //7-10
    ams: u3, //11-13
    shn: u2, //14-15
    iosqes: u4, //16-19
    iocqes: u4, //20-23
    crime: u1, //24
    rsrvd_b: u7, //25-31
};

const VSRegister = packed struct(u32) {
    tet: u8, //0-7
    mnr: u8, //8-15
    mjn: u8, //16-23
    rsvd: u8, //24-31
};

const CSTSRegister = packed struct(u32) {
    rdy: u1, //0
    cfs: u1, //1
    shst: u2, //2-3
    nssro: u1, //4
    pp: u1, //5
    st: u1, //6
    rsvd: u25, //7-31
};

const AQARegister = packed struct(u32) {
    asqs: u12, //0-11
    rsrvd_a: u4 = 0x0, //12-15
    acqs: u12, //16-27
    rsrvd_b: u4 = 0x0, //28-31
};

const ASQEntry = packed struct(u64) {
    asqb: u12, //0-11
    rsrvd: u52, //12-63
};

const ACQEntry = packed struct(u64) {
    acqb: u12, //0-11
    rsrvd: u52, //12-63
};

const RegisterSet = packed struct {
    cap: CAPRegister, //offset: 0x00
    vs: VSRegister, // offset: 0x08
    intms: u32, // offset: 0x0c
    intmc: u32, // off  0x10
    cc: CCRegister,
    rsrvd: u32 = 0,
    csts: CSTSRegister,
    nssrm: u32,
    aqa: AQARegister,
    asq: ASQEntry,
    acq: ACQEntry,
    //sugesset the rest of the registers

};

fn readRegister(T: type, bar: pci.BAR, register_set_field: @TypeOf(.enum_literal)) T {
    return switch (bar.address) {
        inline else => |addr| @as(*volatile T, @ptrFromInt(paging.virtFromMME(addr) + @offsetOf(RegisterSet, @tagName(register_set_field)))).*,
    };
}

fn writeRegister(T: type, bar: pci.BAR, register_set_field: @TypeOf(.enum_literal), value: T) void {
    switch (bar.address) {
        inline else => |addr| @as(*volatile T, @ptrFromInt(paging.virtFromMME(addr) + @offsetOf(RegisterSet, @tagName(register_set_field)))).* = value,
    }

    // switch (bar.address) {
    //     inline else => |addr| {
    //         const offset = @offsetOf(RegisterSet, @tagName(register_set_field));
    //         const ptr: *volatile T = (@ptrFromInt(paging.virtFromMME(addr) + offset));
    //         log.warn("Address: {}, Offset: {x}, Ptr: {}, fieldName:{s}\n", .{ addr, offset, ptr, @tagName(register_set_field) });
    //         log.debug("Writing value: {}\n", .{value});
    //         log.debug("Value before writing: {}\n", .{ptr.*});
    //
    //         //ptr.* = value;
    //
    //         //var x: u32 = 0;
    //         //x = x + 0x01020304;
    //         //_ = &x;
    //         //ptr.* = @bitCast(x);
    //         ptr.* = @bitCast(value);
    //         //
    //         //
    //         // Odczytaj wartość po zapisie, aby sprawdzić, czy operacja się powiodła
    //         const read_back = ptr.*;
    //         log.debug("Read back value: {}\n", .{read_back});
    //     },
    // }
}

pub fn interested(_: Self, class_code: u8, subclass: u8, prog_if: u8) bool {
    return class_code == nvme_class_code and subclass == nvme_subclass and prog_if == nvme_prog_if;
}

pub fn update(_: Self, function: u3, slot: u5, bus: u8, interrupt_line: u8) void {
    const bar = pci.readBARWithArgs(.bar0, function, slot, bus);

    //  bus-mastering DMA, and memory space access in the PCI configuration space
    const command = pci.readRegisterWithArgs(u16, .command, function, slot, bus);
    log.warn("PCI command register: 0b{b:0>16}", .{command});
    // Enable interrupts, bus-mastering DMA, and memory space access in the PCI configuration space for the function.
    pci.writeRegisterWithArgs(u16, .command, function, slot, bus, command | 0b110);

    const virt = switch (bar.address) {
        inline else => |addr| paging.virtFromMME(addr),
    };

    const cap_reg_ptr: *volatile u64 = @ptrFromInt(virt);
    const vs_reg_ptr: *volatile u32 = @ptrFromInt(virt + 0x08);
    const intmc_reg_ptr: *volatile u32 = @ptrFromInt(virt + 0x04);
    const intms_reg_ptr: *volatile u32 = @ptrFromInt(virt + 0x0c);
    const cc_reg_ptr: *volatile u32 = @ptrFromInt(virt + 0x14);
    const csts_reg_ptr: *volatile u32 = @ptrFromInt(virt + 0x1c);
    const aqa_reg_ptr: *volatile u32 = @ptrFromInt(virt + 0x24);
    const asq_reg_ptr: *volatile u64 = @ptrFromInt(virt + 0x28);
    const acq_reg_ptr: *volatile u64 = @ptrFromInt(virt + 0x30);

    const register_set_ptr: *volatile RegisterSet = @ptrFromInt(virt);

    // Adjust if needed page PAT to write-through
    const size: usize = switch (bar.size) {
        .as32 => bar.size.as32,
        .as64 => bar.size.as64,
    };
    paging.adjustPageAreaPAT(virt, size, .write_through) catch |err| {
        log.err("Failed to adjust page area PAT for NVMe BAR: {}", .{err});
        return;
    };
    paging.debugLowestEntryFromVirt(virt); //to be commented out
    // End of adjustment

    //log register_set_ptr content
    log.debug("NVMe register set at address {}:", .{register_set_ptr.*});

    log.debug(
        \\bar:{}, addr:0x{x},
        \\cap: 0b{b:0>64}, vs: 0b{b:0>32}
        \\intms: 0b{b:0>32}, intmc: 0b{b:0>32}
        \\cc: 0b{b:0>32}, csts: 0b{b:0>32}
        \\aqa: 0b{b:0>32}, asq: 0b{b:0>64}, acq: 0b{b:0>64}
    , .{
        bar,
        virt,
        cap_reg_ptr.*,
        vs_reg_ptr.*,
        intms_reg_ptr.*,
        intmc_reg_ptr.*,
        cc_reg_ptr.*,
        csts_reg_ptr.*,
        aqa_reg_ptr.*,
        asq_reg_ptr.*,
        acq_reg_ptr.*,
    });

    // Check the controller version
    const vs = readRegister(VSRegister, bar, .vs);
    log.info("NVMe controller version: {}.{}.{}", .{ vs.mjn, vs.mnr, vs.tet });

    // support only NVMe 1.4 and 2.0
    if (vs.mjn == 1 and vs.mnr < 4) {
        log.err("Unsupported NVMe controller major version:  {}.{}.{}", .{ vs.mjn, vs.mnr, vs.tet });
        return;
    }

    // Check if the controller supports NVM Command Set and Admin Command Set
    const cap = readRegister(CAPRegister, bar, .cap);
    if (cap.css.nvmcs == 0) {
        log.err("NVMe controller does not support NVM Command Set", .{});
        return;
    }

    if (cap.css.acs == 0) {
        log.err("NVMe controller does not support Admin Command Set", .{});
        return;
    }

    log.info("NVMe controller supports min/max memory page size: 2^(12 + cap.mpdmin:{d}) -> 2^(12 + cap.mpdmssx: {d}), 2^(12 + cc.mps: {d})", .{ cap.mpsmin, cap.mpsmax, @as(*CCRegister, @ptrCast(@volatileCast(cc_reg_ptr))).*.mps });
    // const mpsmin =  std.math.powi(u64, 2,  12 + cap.mpsmin) catch |err| {
    //     log.err("Failed to calculate min memory page size: {}", .{err});
    //     return;
    // };
    // const mpsmax =  std.math.powi(u64, 2, @as(u64, 12 + cap.mpsmax) ) catch |err| {
    //     log.err("Failed to calculate max memory page size: {}", .{err});
    //     return;
    // };
    // log.info("NVMe controller supports min/max memory page size: {d}/{d}", .{mpsmin, mpsmax});

    // Check the capabilities for support of the host's memory page size
    if (cap.mpsmin > 0) {
        log.err("NVMe controller does not support the host's memory page size", .{});
        return;
    }

    // Reset the controller
    var cc = readRegister(CCRegister, bar, .cc);
    log.info("CC register before reset: {}", .{cc});
    cc.en = 0;
    log.info("CC register before reset with enable flag disabled: {}", .{cc});
    writeRegister(CCRegister, bar, .cc, cc);
    cc = readRegister(CCRegister, bar, .cc); // all fields should be 0
    log.info("CC register after reset: {}", .{cc});

    // Wait the controller to be disabled
    while (readRegister(CSTSRegister, bar, .csts).rdy != 0) {}

    log.info("NVMe controller is disabled", .{});

    //set AQA queue size
    var aqa = readRegister(AQARegister, bar, .aqa);
    log.info("NVMe AQA Register: {}/0x{x}", .{ aqa, aqa_reg_ptr.* });
    aqa.asqs = 0xa;
    aqa.acqs = 0xb;
    writeRegister(AQARegister, bar, .aqa, aqa);
    log.info("NVMe AQA value to write: {}", .{aqa});
    //aqa_reg_ptr.* = @bitCast(aqa);
    const aqa2 = readRegister(AQARegister, bar, .aqa);
    log.info("NVMe AQA Register: {}", .{aqa2});

    log.warn("offset of {s} is 0x{x}", .{ "cap", @offsetOf(RegisterSet, "cap") });
    log.warn("offset of {s} is 0x{x}", .{ "vs", @offsetOf(RegisterSet, "vs") });
    log.warn("offset of {s} is 0x{x}", .{ "intms", @offsetOf(RegisterSet, "intms") });
    log.warn("offset of {s} is 0x{x}", .{ "intmc", @offsetOf(RegisterSet, "intmc") });
    log.warn("offset of {s} is 0x{x}", .{ "cc", @offsetOf(RegisterSet, "cc") });
    log.warn("offset of {s} is 0x{x}", .{ "csts", @offsetOf(RegisterSet, "csts") });
    log.warn("offset of {s} is 0x{x}", .{ "nssrm", @offsetOf(RegisterSet, "nssrm") });
    log.warn("offset of {s} is 0x{x}", .{ "aqa", @offsetOf(RegisterSet, "aqa") });
    log.warn("offset of {s} is 0x{x}", .{ "asq", @offsetOf(RegisterSet, "asq") });
    log.warn("offset of {s} is 0x{x}", .{ "acq", @offsetOf(RegisterSet, "acq") });

    // TODO: remove this
    log.info("NVMe interrupt line: {}", .{interrupt_line});
    const unique_id = pci.uniqueId(bus, slot, function);
    int.addISR(interrupt_line, .{ .unique_id = unique_id, .func = handleInterrupt }) catch |err| {
        log.err("Failed to add NVMe interrupt handler: {}", .{err});
    };
}

fn handleInterrupt() !void {
    log.warn("We've got it: NVMe interrupt", .{});
}

var driver = &pci.Driver{ .nvme = &Self{} };

pub fn init() void {
    log.info("Initializing NVMe driver", .{});
    pci.registerDriver(driver) catch |err| {
        log.err("Failed to register NVMe driver: {}", .{err});
        @panic("Failed to register NVMe driver");
    };
}

pub fn deinit() void {
    log.info("Deinitializing NVMe driver", .{});
    // TODO: for now we don't have a way to unregister the driver
}
