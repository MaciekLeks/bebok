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
        ms: u16, //0-15 - Metadata Size
        lbads: u8, //4-7 - LBA Data Size
        rp: u2, //8 - Relative Performance
        rsvd: u6, //9-11
    };

    nsze: u64, //8bytes - Namespace Size in logical blocks
    ncap: u64, //8bytes - Namespace Capacity
    nuse: u64, //8bytes - Namespace Utilization
    nsfeat: packed struct(u8) {
        thinp: u1, //0 - Thin Provisioning
        nsabp: u1, //1
        dae: u1, //2
        uidreuse: u1, //3
        optperf: u1, //4
        rsrv: u3, //5-7
    }, //1byte - Namespace Features
    nlbaf: u8, //1byte - Number of LBA Formats
    flbas: u8, //1byte - Formatted LBA Size (lbaf array index)
    mc: u8, //1byte - Metadata Capabilities
    dpc: u8, //1byte - End-to-end Data Protection Capabilities
    dps: u8, //1byte - End-to-end Data Protection Type Settings
    nmic: u8, //1byte - Namespace Multi-path I/O and Namespace Sharing Capabilities
    rescap: u8, //1byte - Reservation Capabilities
    fpi: u8, //1byte - Format Progress Indicator
    //fill gap to the.128 byte of the 4096 bytes
    dlfeat: enum(u8) {
        read_not_reported = 0b000,
        deallocated_lba_cleared = 0b001,
        deallocated_lba_not_cleared = 0b010, //reported as 0xff
    }, //1byte - Deallocate Logical Block Features
    ignrd_a: [128 - 31]u8,
    lbaf: [64]LBAFormatInfo, //16bytes - LBA Format
    //fill gap to the 4096 bytes
    // ignrd_b: [4096 - 384]u8,
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
