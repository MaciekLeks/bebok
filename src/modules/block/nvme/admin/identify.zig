const std = @import("std");
const cmd = @import("command.zig");
const com = @import("../commons.zig");

pub const IdentifyCommand = packed struct(u512) {
    cdw0: cmd.AdminCDw0, //00:03 byte
    nsid: u32 = 0, //04:07 byte - nsid
    ignrd_b: u32 = 0, //08:11 byte - cdw2
    ignrd_c: u32 = 0, //12:15 byte = cdw3
    ignrd_e: u64 = 0, //16:23 byte = mptr
    dptr: com.DataPointer, //24:39 byte = prp1, prp2
    cns: u8, //00:07 id cdw10
    rsrv_a: u8 = 0, //08:15 in cdw10
    cntid: u16 = 0, //16-31 in cdw10
    // ignrd_f: u32 = 0, //44:47 in cdw11
    cnssi: u16 = 0, //00:15 in cdw11 - SNS Specific Identifier
    rsrvd_b: u8 = 0, //16:23 in cdw11
    csi: u8 = 0, //24:31 in cdw11 - Command Specific Information
    ignrd_g: u32 = 0, //48-52 in cdw12
    ignrd_h: u32 = 0, //52-55 in cdw13
    uuid: u7 = 0, //00-06 in cdw14
    rsrvd_c: u25 = 0, //07-31 in cdw14
    ignrd_j: u32 = 0, //60-63 in cdw15
};

// Identify CNS = 0x00
pub const IdentifyNamespaceInfo = extern struct {
    const LBAFormatInfo = packed struct(u32) {
        ms: u16, // Metadata Size
        lbads: u8, // LBA Data Size
        rp: u2, // Relative Performance
        rsvd: u6, // Reserved
    };

    nsze: u64 align(1), // Namespace Size
    ncap: u64 align(1), // Namespace Capacity
    nuse: u64 align(1), // Namespace Utilization
    nsfeat: packed struct(u8) {
        thinp: u1, // Thin Provisioning
        nsabp: u1, // Namespace Atomic Boundaries
        dae: u1, // Deallocate
        uidreuse: u1, // UID Reuse
        optperf: u1, // Optimal Performance
        rsrv: u3, // Reserved
    } align(1),
    nlbaf: u8 align(1), // Number of LBA Formats
    flbas: u8 align(1), // Formatted LBA Size
    mc: u8 align(1), // Metadata Capabilities
    dpc: u8 align(1), // End-to-end Data Protection Capabilities
    dps: u8 align(1), // End-to-end Data Protection Type Settings
    nmic: u8 align(1), // Namespace Multi-path I/O and Namespace Sharing Capabilities
    rescap: u8 align(1), // Reservation Capabilities
    fpi: u8 align(1), // Format Progress Indicator
    dlfeat: u8 align(1), // Deallocate Logical Block Features
    nawun: u16 align(1), // Namespace Atomic Write Unit Normal
    nawupf: u16 align(1), // Namespace Atomic Write Unit Power Fail
    nacwu: u16 align(1), // Namespace Atomic Compare & Write Unit
    nabsn: u16 align(1), // Namespace Atomic Boundary Size Normal
    nabo: u16 align(1), // Namespace Atomic Boundary Offset
    nabspf: u16 align(1), // Namespace Atomic Boundary Size Power Fail
    noiob: u16 align(1), // Namespace Optimal I/O Boundary
    nvmcap: u128 align(1), // NVM Capacity
    npwg: u16 align(1), // Namespace Preferred Write Granularity )
    npwa: u16 align(1), // Namespace Preferred Write Alignment
    npdg: u16 align(1), // Namespace Preferred Deallocate Granularity
    npda: u16 align(1), // Namespace Preferred Deallocate Alignment
    nows: u16 align(1), // Namespace Optimal Write Size )
    mssrl: u16 align(1), // Minimum Single Source Range Lenght (bytes 74-75)
    mcl: u32 align(1), // Meximum Copy Length (bytes 76-79)
    msrc: u8 align(1), // Maximum Source Range Cout( byte 80)
    rsrv_a: [11]u8 align(1), // Reserved (bytes 81-91)
    anagrpid: u32 align(1), // ANA Group Identifier (bytes 92-95)
    rsrvd_b: [3]u8 align(1), // Reserved (bytes 96-98)
    nsattr: u8 align(1), // Namespace Attributes (bytes 99)
    nvmsetid: u16 align(1), // NVM Set Identifier (bytes 100-101)
    endgid: u16 align(1), // Endurance Group Identifier (bytes 102-103)
    nguid: [16]u8 align(1), // Namespace Globally Unique Identifier
    eui64: [8]u8 align(1), // IEEE Extended Unique Identifier
    lbaf: [64]LBAFormatInfo align(1), // LBA Format Support
    vs: [3712]u8 align(1), // Vendor Specific (bytes 384-4095)

    pub fn format(
        self: IdentifyNamespaceInfo,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = try writer.print("IdentifyNamespaceInfo[ nsze:{d}, ncap:{d}, nuse:{d} ]", .{ self.nsze, self.ncap, self.nuse });
    }
};

pub const NsInfo = IdentifyNamespaceInfo; //alias for Identify0x00Info

/// Identify CNS = 0x01
pub const ControllerInfo = extern struct {
    vid: u16, // 2bytes
    ssvid: u16, //2bytes
    sn: [20]u8, //20bytes
    mn: [40]u8, //40bytes
    fr: [8]u8, //8bytes
    rab: u8, //1byte
    ieee: [3]u8, //3bytes
    cmic: u8, //1byte
    mdts: u8, //1byte Maximum Data Transfer Size
    cntlid: u16, //2bytes
    ver: u32, //4bytes
    //fill gap to 111 bytes
    ignrd_a: [111 - 84]u8,
    cntrltype: u8, //111 bajt
    //ignore till 256 bytes
    ignrd_b: [256 - 112]u8,
    oacs: u16, //256-257 Optional Admin Command Support
    //ignroe till the 512 bytes
    ignrd_c: [512 - 258]u8,
    sqes: packed struct(u8) {
        min: u4, //0-3 Minimum Submission Queue Entry Size
        max: u4, //4-7 Maximum Submission Queue Entry Size
    }, //512-513 Submission Queue Entry Size
    cqes: packed struct(u8) {
        min: u4, //0-3 Minimum Completion Queue Entry Size
        max: u4, //4-7 Maximum Completion Queue Entry Size
    }, //514-515 Completion Queue Entry Size

};

/// Identify CNS = 0x05
pub const IoCommandSetNamespaceInfo = extern struct {
    lbmstm: u64, //8bytes Logical Block Memory Storage Tag Mask
    pic: u8, //1byte Protection Information Capabilities
    rsrvd_a: u16 = 0, //2byte s
    rsrvd_b: u8 = 0, //1byte
    elbaf: [64]u32, //4bytes Extend LBA Format 0 Support
};

// Identify CNS = 0x06
pub const IoCommandSetControllerInfo = extern struct {
    vsl: u8, //1byte Verify Size Limit
    wzsl: u8, //1byte Write Zeroes Size Limit
    wusl: u8, //1byte Write Uncorrectable Size Limit
    dmrl: u8, //1byte Dataset Management Ranges Limit
    dmrsl: u32, //4bytes Dataset Management Range Size List
    dmsl: u64, //8bytes Dataset Management Size Limit
};

// Identify CNS = 0x08
pub const IoCommandSetIndependentNamespaceInfo = extern struct {
    nsfeat: u8, //1byte Namespace Features
    nmic: u8, //1byte Namespace Multi-path I/O and Namespace Sharing Capabilities
    rescap: u8, //1byte Reservation Capabilities
    fpi: u8, //1byte Format Progress Indicator
    anagrpid: u32, //4bytes ANA Group Identifier
    nsattr: u8, //1byte Namespace Attributes
    rsrvd: u8 = 0, //1byte
    nvmsetid: u16, //2bytes NVM Set Identifier
    endgid: u16, //2bytes End-to-end Group Identifier
    nstate: u8, //1byte Namespace State
};

// Identify CNS = 0x1c
// Each vector consists of 0 to 3 command set indexes, each 1 byte long
pub const IoCommandSet = packed struct(u64) {
    nvmcs: u1, //0 - NVM Command Set
    kvcs: u1, //1 - Key Value Command Set
    zncs: u1, //2 - Zone Namespace Command Set
    //fill gap to 64 bytes
    rsrvd: u61,
};
