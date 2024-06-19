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
    rsrvd_a: u4, //12-15
    acqs: u12, //16-27
    rsrvd_b: u4, //28-31
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
    cap: CAPRegister,
    vs: VSRegister,
    intms: u32,
    intmc: u32,
    cc: CCRegister,
    csts: CSTSRegister,
    aqa: AQARegister,
    asq: ASQEntry,
    acq: ACQEntry,
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
}

pub fn interested(_: Self, class_code: u8, subclass: u8, prog_if: u8) bool {
    return class_code == nvme_class_code and subclass == nvme_subclass and prog_if == nvme_prog_if;
}

pub fn update(_: Self, function: u3, slot: u5, bus: u8, interrupt_line: u8) void {
    const bar = pci.readBARWithArgs(.bar0, function, slot, bus);

    //  bus-mastering DMA, and memory space access in the PCI configuration space
    const command = pci.readRegisterWithArgs(u16, .command, function, slot, bus);
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
    log.warn("NVMe register set at address {}:", .{register_set_ptr.*});

    log.warn(
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

    // Reset the controller
    var cc = readRegister(CCRegister, bar, .cc);
    cc.en = 0;
    writeRegister(CCRegister, bar, .cc, cc);

    // Wait the controller to be disabled
    while (readRegister(CSTSRegister, bar, .csts).rdy != 0) {}

    log.info("NVMe controller is disabled", .{});

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

    // TODO: remove this
    log.warn("NVMe interrupt line: {}", .{interrupt_line});
    const unique_id = pci.uniqueId(bus, slot, function);
    int.addHandler(interrupt_line, .{ .unique_id = unique_id, .handle_fn = handleInterrupt}) catch |err| {
        log.err("Failed to add NVMe interrupt handler: {}", .{err});
    };
}

fn handleInterrupt() void{
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
