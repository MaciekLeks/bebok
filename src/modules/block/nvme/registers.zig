const std = @import("std");

const Pcie = @import("deps.zig").Pcie;
const paging = @import("deps.zig").paging;

const log = std.log.scoped(.drivers_nvme);

pub fn readRegister(T: type, bar: Pcie.Bar, register_set_field: @TypeOf(.enum_literal)) T {
    return switch (bar.address) {
        inline else => |addr| @as(*volatile T, @ptrFromInt(paging.virtFromMME(addr) + @offsetOf(RegisterSet, @tagName(register_set_field)))).*,
    };
}

pub fn writeRegister(T: type, bar: Pcie.Bar, register_set_field: @TypeOf(.enum_literal), value: T) void {
    switch (bar.address) {
        inline else => |addr| @as(*volatile T, @ptrFromInt(paging.virtFromMME(addr) + @offsetOf(RegisterSet, @tagName(register_set_field)))).* = value,
    }
}

pub const RegisterSet = packed struct {
    cap: CAPRegister,
    vs: VSRegister,
    intms: u32,
    intmc: u32,
    cc: CCRegister,
    rsrvd: u32 = 0,
    csts: CSTSRegister,
    nssr: u32,
    aqa: AQARegister,
    asq: ASQEntry,
    acq: ACQEntry,
};

pub const CAPRegister = packed struct(u64) {
    const CSSField = packed struct(u8) {
        nvmcs: u1, //0 NVM Command Set or Discovery Controller
        rsrvd: u5, //1-5
        iocs: u1, //6 I/O Command Set
        acs: u1, //7 Admin Command Set only
    };
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

pub const CCRegister = packed struct(u32) {
    const ArbitrationMechanism = enum(u3) {
        round_robin = 0b0,
        weighted_round_robin = 0b1,
        vendor_specific = 0b111,
    };
    en: u1, //0 use to reset the controller
    rsrvd_a: u3, //1-3
    css: u3, //4-6
    mps: u4, //7-10
    ams: ArbitrationMechanism, //11-13
    shn: u2, //14-15
    iosqes: u4, //16-19
    iocqes: u4, //20-23
    crime: u1, //24
    rsrvd_b: u7, //25-31
};

pub const VSRegister = packed struct(u32) {
    tet: u8, //0-7
    mnr: u8, //8-15
    mjn: u8, //16-23
    rsvd: u8, //24-31
};

pub const CSTSRegister = packed struct(u32) {
    rdy: u1, //0
    cfs: u1, //1
    shst: u2, //2-3
    nssro: u1, //4
    pp: u1, //5
    st: u1, //6
    rsvd: u25, //7-31
};

pub const AQARegister = packed struct(u32) {
    asqs: u12, //0-11
    rsrvd_a: u4 = 0x0, //12-15
    acqs: u12, //16-27
    rsrvd_b: u4 = 0x0, //28-31
};

pub const ASQEntry = packed struct(u64) {
    rsrvd: u12 = 0, //0-11
    asqb: u52, //0-11
};

pub const ACQEntry = packed struct(u64) {
    rsrvd: u12, //12-63
    acqb: u52, //0-11
};
