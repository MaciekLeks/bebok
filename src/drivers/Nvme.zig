const std = @import("std");
const log = std.log.scoped(.nvme);
const pci = @import("pci.zig");
const paging = @import("../paging.zig");
const int = @import("../int.zig");
const pmm = @import("../mem/pmm.zig");
const heap = @import("../mem/heap.zig").heap;
const math = std.math;

const nvme_class_code = 0x01;
const nvme_subclass = 0x08;
const nvme_prog_if = 0x02;

const nvme_iosqs = 0x2; //submisstion queue size(length)
const nvme_iocqs = 0x2; //completion queue size
const nvme_ioasqs = 0x2; //admin submission queue size
const nvme_ioacqs = 0x2; //admin completion queue size

const nvme_ncqr = 0x1; //number of completion queues requested - TODO only one cq now
const nvme_nsqr = 0x1; //number of submission queues requested - TODO only one sq now

const Self = @This();

const NVMeError = error{ InvalidCommand, InvalidCommandSequence, AdminCommandNoData, AdminCommandFailed };

const CSSField = packed struct(u8) {
    nvmcs: u1, //0 NVM Command Set or Discovery Controller
    rsrvd: u5, //1-5
    iocs: u1, //6 I/O Command Set
    acs: u1, //7 Admin Command Set only
};

const ControllerType = enum(u8) {
    io_controller = 1,
    discovery_controller = 2,
    admin_controller = 3,
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

const ArbitrationMechanism = enum(u3) {
    round_robin = 0b0,
    weighted_round_robin = 0b1,
    vendor_specific = 0b111,
};

const CCRegister = packed struct(u32) {
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
    rsrvd: u12 = 0, //0-11
    asqb: u52, //0-11
};

const ACQEntry = packed struct(u64) {
    rsrvd: u12, //12-63
    acqb: u52, //0-11
};

const RegisterSet = packed struct {
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

const AdminOpcode = enum(u8) {
    identify = 0x06,
    abort = 0x0c,
    set_features = 0x09,
    get_features = 0x0a,
    create_io_sq = 0x01,
    delete_io_sq = 0x02,
    create_io_cq = 0x05,
    delete_io_cq = 0x07,
};

const NSID = u32;

const CDW0 = packed struct(u32) {
    opc: AdminOpcode,
    fuse: u2 = 0, //0 for nromal operation
    rsvd: u4 = 0,
    psdt: u2 = 0, //0 for PRP tranfer
    cid: u16,
};

const DataPointer = packed union {
    prp: packed struct(u128) {
        prp1: u64,
        prp2: u64 = 0,
    },
    sgl: packed struct(u128) {
        sgl1: u128,
    },
};

// TODO: When packed tagged unions are supported, we can use the following definitions
// const SQEntry = packed union(enum) {
//    identify: IdentifyCommand, //or body of the command
//    abort: AbortCommand,
//    //...
// };

const SQEntry = u512;
const IdentifyCommand = packed struct(u512) {
    cdw0: CDW0, //00:03 byte
    nsid: u32 = 0, //04:07 byte - nsid
    ignrd_b: u32 = 0, //08:11 byte - cdw2
    ignrd_c: u32 = 0, //12:15 byte = cdw3
    ignrd_e: u64 = 0, //16:23 byte = mptr
    dptr: DataPointer, //24:39 byte = prp1, prp2
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

const GetFeaturesCommand = packed struct(u512) {
    cdw0: CDW0, //00:03 byte
    ignrd_a: u32 = 0, //04:07 byte - nsid
    ignrd_b: u32 = 0, //08:11 byte - cdw2
    ignrd_c: u32 = 0, //12:15 byte = cdw3
    ignrd_e: u64 = 0, //16:23 byte = mptr
    dptr: DataPointer, //24:39 byte = prp1, prp2
    fid: u8, //00:07 id cdw10 - Feature Identifier
    sel: enum(u3) {
        current = 0b000,
        default = 0b001,
        saved = 0b010,
        supported_capabilities = 0b011,
    }, //08:10 in cdw10 - Select
    rsrvd_a: u21 = 0, //11-31 in cdw10 - Reserved
    ignrd_f: u32 = 0, //32-63 in cdw11 - I/O Command Set Combination Index
    ignrd_g: u32 = 0, //48-52 in cdw12
    ignrd_h: u32 = 0, //52-55 in cdw13
    ignrd_i: u32 = 0, //56-59 in cdw14
    ignrd_j: u32 = 0, //60-63 in cdw15
};

const SetFeatures0x19Command = packed struct(u512) {
    cdw0: CDW0, //00:03 byte
    ignrd_a: u32 = 0, //04:07 byte - nsid
    ignrd_b: u32 = 0, //08:11 byte - cdw2
    ignrd_c: u32 = 0, //12:15 byte = cdw3
    ignrd_e: u64 = 0, //16:23 byte = mptr
    dptr: DataPointer, //24:39 byte = prp1, prp2
    fid: u8, //00:07 id cdw10 - Feature Identifier
    rsrv_a: u23 = 0, //08:30 in cdw10
    sv: u1, //16-31 in cdw10 - Save
    iosci: u9, //32-40 in cdw11 - I/O Command Set Combination Index
    rsrvd_b: u23 = 0, //41-63 in cdw11
    ignrd_f: u32 = 0, //48-52 in cdw12
    ignrd_g: u32 = 0, //52-55 in cdw13
    uuid: u7 = 0, //00-06 in cdw14 - UUID
    rsrvd_c: u25 = 0, //07-31 in cdw14
    ignrd_h: u32 = 0, //60-63 in cdw15
};

// Create I/O Completion Queue Command
const CreateIOCQCommand = packed struct(u512) {
    cdw0: CDW0, //00:03 byte
    ignrd_a: u32 = 0, //04:07 byte - nsid
    ignrd_b: u32 = 0, //08:11 byte - cdw2
    ignrd_c: u32 = 0, //12:15 byte = cdw3
    ignrd_e: u64 = 0, //16:23 byte = mptr
    dptr: DataPointer, //24:39 byte = prp1, prp2
    qid: u16, //00:15 in cdw10 - Queue Identifier
    qsize: u16, //16:31 in cdw10 - Queue Size
    pc: bool, //32 in cdw11 - Physically Contiguous
    ien: bool, //33 in cdw11 - Interrupt Enable
    rsrvd_a: u14 = 0, //02-15 in cdw11
    iv: u16, //16-31 in cdw11- Interrupt Vector
    ignrd_f: u32 = 0, //32-63 in cdw12
    ignrd_g: u32 = 0, //48-52 in cdw13
    ignrd_h: u32 = 0, //52-55 in cdw14
    ignrd_i: u32 = 0, //56-59 in cdw15
};

const CreateIOSQCommand = packed struct(u512) {
    cdw0: CDW0, //00:03 byte
    nsid: u32, //04:07 byte - nsid
    ignrd_b: u32 = 0, //08:11 byte - cdw2
    ignrd_c: u32 = 0, //12:15 byte = cdw3
    ignrd_e: u64 = 0, //16:23 byte = mptr
    dptr: DataPointer, //24:39 byte = prp1, prp2
    qid: u16, //00:15 in cdw10 - Queue Identifier
    qsize: u16, //16:31 in cdw10 - Queue Size
    cqid: u16, //00:15 in cdw11 - Completion Queue Identifier
    pc: bool, //16 in cdw11 - Physically Contiguous
    ien: bool, //17 in cdw11 - Interrupt Enable
    rsrvd_a: u14 = 0, //18-31 in cdw11
    iv: u16, //00-15 in cdw11 - Interrupt Vector
    ignrd_f: u32 = 0, //16-47 in cdw12
    ignrd_g: u32 = 0, //48-52 in cdw13
    ignrd_h: u32 = 0, //52-55 in cdw14
    ignrd_i: u32 = 0, //56-59 in cdw15
};

const LBAFormatInfo = packed struct(u32) {
    ms: u16, //0-15 - Metadata Size
    lbads: u8, //4-7 - LBA Data Size
    rp: u2, //8 - Relative Performance
    rsvd: u6, //9-11
};

const Identify0x00Info = extern struct {
    nsize: u64, //8bytes - Namespace Size
    ncap: u64, //8bytes - Namespace Capacity
    nuse: u64, //8bytes - Namespace Utilization
    nsfeat: u8, //1byte - Namespace Features
    nlbaf: u8, //1byte - Number of LBA Formats
    flbas: u8, //1byte - Formatted LBA Size
    mc: u8, //1byte - Metadata Capabilities
    dpc: u8, //1byte - End-to-end Data Protection Capabilities
    dps: u8, //1byte - End-to-end Data Protection Type Settings
    nmic: u8, //1byte - Namespace Multi-path I/O and Namespace Sharing Capabilities
    rescap: u8, //1byte - Reservation Capabilities
    fpi: u8, //1byte - Format Progress Indicator
    //fill gap to the.128 byte of the 4096 bytes
    ignrd_a: [128 - 32]u8,
    lbaf: [64]LBAFormatInfo, //16bytes - LBA Format
    //fill gap to the 4096 bytes
    // ignrd_b: [4096 - 384]u8,
};

const Identify0x01Info = extern struct {
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

const Identify0x05Info = extern struct {
    lbmstm: u64, //8bytes Logical Block Memory Storage Tag Mask
    pic: u8, //1byte Protection Information Capabilities
    rsrvd_a: u16 = 0, //2byte s
    rsrvd_b: u8 = 0, //1byte
    elbaf: [64]u32, //4bytes Extend LBA Format 0 Support
};

const Identify0x06Info = extern struct {
    vsl: u8, //1byte Verify Size Limit
    wzsl: u8, //1byte Write Zeroes Size Limit
    wusl: u8, //1byte Write Uncorrectable Size Limit
    dmrl: u8, //1byte Dataset Management Ranges Limit
    dmrsl: u32, //4bytes Dataset Management Range Size List
    dmsl: u64, //8bytes Dataset Management Size Limit
};

const Identify0x08Info = extern struct {
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

// Each vector consists of 0 to 3 command set indexes, each 1 byte long
const Identify0x1cCommandSetVector = packed struct(u64) {
    nvmcs: u1, //0 - NVM Command Set
    kvcs: u1, //1 - Key Value Command Set
    zncs: u1, //2 - Zone Namespace Command Set
    //fill gap to 64 bytes
    rsrvd: u61,
};

const CQEStatusField = packed struct(u15) {
    // Staus Code
    sc: u8 = 0, //0-7
    // Status Code Type
    sct: u3 = 0, //8-10
    // Command Retry Delay
    crd: u2 = 0, //11-12
    // More
    m: u1 = 0, //13
    // Do Not Retry
    dnr: u1 = 0, //14

};

const CQEntry = packed struct(u128) {
    cmd_res0: u32 = 0,
    cmd_res1: u32 = 0,
    sq_header_pos: u16 = 0, //it's called pointer but it's not a pointer it's an index in fact
    sq_id: u16 = 0,
    cmd_id: u16 = 0,
    phase: u1 = 0,
    status: CQEStatusField = .{},
};

fn Queue(EntryType: type) type {
    return struct {
        entries: []volatile EntryType = undefined,
        tail_pos: u32 = 0,
        tail_dbl: *volatile u32 = undefined,
        head_pos: u32 = 0,
        head_dbl: *volatile u32 = undefined,
        expected_phase: u1 = 1,
    };
}

const Drive = struct {
    sqa: []volatile SQEntry = undefined,
    cqa: []volatile CQEntry = undefined,
    sq: []volatile SQEntry = undefined,
    cq: []volatile CQEntry = undefined,

    sqa_tail_pos: u32 = 0, // private counter to keep track and update sqa_tail_dbl
    sqa_header_pos: u32 = 0, //contoller position retuned in CQEntry as sq_header_pos
    sqa_tail_dbl: *volatile u32 = undefined, //each doorbell value is u32, minmal doorbell stride is 4 (2^(2+CAP.DSTRD))
    cqa_head_pos: u32 = 0,
    cqa_head_dbl: *volatile u32 = undefined, //each doorbell value is u32, minmal doorbell stride is 4 (2^(2+CAP.DSTRD))

    //sq_tail_pos: u32 = 0, //private counter to keep track and update sq_tail_dbl
    //sq_tail_dbl: *volatile u32 = undefined,
    //cq_head_dbl: *volatile u32 = undefined,

    expected_phase: u1 = 1, //private counter to keep track of the expected phase
    mdts_bytes: u32 = 0, // Maximum Data Transfer Size in bytes

    ncqr: u16 = 1, //number of completion queues requested - TODO only one cq now
    nsqr: u16 = 1, //number of submission queues requested - TODO only one sq now

    iocq: [nvme_ncqr]Queue(CQEntry) = undefined,
    iosq: [nvme_nsqr]Queue(SQEntry) = undefined,
};

var drive: Drive = undefined; //TODO only one drive now

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
    drive = .{}; //TODO replace it for more drives

    const VEC_NO: u16 = 0x20 + interrupt_line; //TODO: we need MSI/MSI-X support first - PIC does not work here
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
    log.info("NVME CAP Register: {}", .{cap});
    if (cap.css.nvmcs == 0) {
        log.err("NVMe controller does not support NVM Command Set", .{});
        return;
    }

    if (cap.css.acs == 0) {
        log.err("NVMe controller does not support Admin Command Set", .{});
        return;
    }

    log.info("NVMe controller supports min/max memory page size: 2^(12 + cap.mpdmin:{d}) -> 2^(12 + cap.mpdmssx: {d}), 2^(12 + cc.mps: {d})", .{ cap.mpsmin, cap.mpsmax, @as(*CCRegister, @ptrCast(@volatileCast(cc_reg_ptr))).*.mps });

    const sys_mps: u4 = @intCast(math.log2(pmm.page_size) - 12);
    if (cap.mpsmin < sys_mps or sys_mps > cap.mpsmax) {
        log.err("NVMe controller does not support the host's memory page size", .{});
        return;
    }

    // Reset the controller
    disableController(bar);

    // The host configures the Admin Queue by setting the Admin Queue Attributes (AQA), Admin Submission Queue Base Address (ASQ), and Admin Completion Queue Base Address (ACQ) the appropriate values;
    //set AQA queue sizes
    var aqa = readRegister(AQARegister, bar, .aqa);
    log.info("NVMe AQA Register pre-modification: {}", .{aqa});
    aqa.asqs = nvme_ioasqs;
    aqa.acqs = nvme_ioacqs;
    writeRegister(AQARegister, bar, .aqa, aqa);
    aqa = readRegister(AQARegister, bar, .aqa);
    log.info("NVMe AQA Register post-modification: {}", .{aqa});

    // ASQ and ACQ setup
    drive.sqa = heap.page_allocator.alloc(SQEntry, nvme_ioasqs) catch |err| {
        log.err("Failed to allocate memory for admin submission queue entries: {}", .{err});
        return;
    };
    @memset(drive.sqa, 0);
    drive.cqa = heap.page_allocator.alloc(CQEntry, nvme_ioacqs) catch |err| {
        log.err("Failed to allocate memory for admin completion queue entries: {}", .{err});
        return;
    };

    const sqa_phys = paging.physFromPtr(drive.sqa.ptr) catch |err| {
        log.err("Failed to get physical address of admin submission queue: {}", .{err});
        return;
    };
    const cqa_phys = paging.physFromPtr(drive.cqa.ptr) catch |err| {
        log.err("Failed to get physical address of admin completion queue: {}", .{err});
        return;
    };
    @memset(drive.cqa, .{});

    log.debug("ASQ: virt: {*}, phys:0x{x}; ACQ: virt:{*}, phys:0x{x}", .{ drive.sqa, sqa_phys, drive.cqa, cqa_phys });

    var asq = readRegister(ASQEntry, bar, .asq);
    log.info("ASQ Register pre-modification: 0x{x}", .{@shlExact(asq.asqb, 12)});
    asq.asqb = @intCast(@shrExact(sqa_phys, 12)); // 4kB aligned
    writeRegister(ASQEntry, bar, .asq, asq);
    asq = readRegister(ASQEntry, bar, .asq);
    log.info("ASQ Register post-modification: 0x{x}", .{@shlExact(asq.asqb, 12)});

    var acq = readRegister(ACQEntry, bar, .acq);
    log.info("ACQ Register pre-modification: 0x{x}", .{@shlExact(acq.acqb, 12)});
    acq.acqb = @intCast(@shrExact(cqa_phys, 12)); // 4kB aligned
    writeRegister(ACQEntry, bar, .acq, acq);
    acq = readRegister(ACQEntry, bar, .acq);
    log.info("ACQ Register post-modification: 0x{x}", .{@shlExact(acq.acqb, 12)});

    var cc = readRegister(CCRegister, bar, .cc);
    log.info("CC register pre-modification: {}", .{cc});
    //CC.css settings
    if (cap.css.acs == 1) cc.css = 0b111;
    if (cap.css.iocs == 1) cc.css = 0b110 else if (cap.css.nvmcs == 0) cc.css = 0b000;
    // Set page size as the host's memory page size
    cc.mps = sys_mps;
    // Set the arbitration mechanism to round-robin
    cc.ams = .round_robin;
    cc.iosqes = 6; // 64 bytes - set to recommened value
    cc.iocqes = 4; // 16 bytes - set to
    writeRegister(CCRegister, bar, .cc, cc);
    log.info("CC register post-modification: {}", .{readRegister(CCRegister, bar, .cc)});

    enableController(bar);

    const doorbell_base: usize = virt + 0x1000;
    const doorbell_size = math.pow(u32, 2, 2 + cap.dstrd);
    drive.sqa_tail_dbl = @ptrFromInt(doorbell_base + doorbell_size * 0);
    drive.cqa_head_dbl = @ptrFromInt(doorbell_base + doorbell_size * 1);
    // for (drive.iosq, 1..) |sq, sq_dbl_idx| {
    //     sq.tail_dbl = @ptrFromInt(doorbell_base + doorbell_size * (2 * sq_dbl_idx));
    // }
    // for (drive.iocq, 1..) |cq, cq_dbl_idx| {
    //     cq.q_head_dbl = @ptrFromInt(doorbell_base + doorbell_size * (2 * cq_dbl_idx + 1));
    // }
    //
    log.info("NVMe interrupt line: {x}, vector number: 0x{x}", .{ interrupt_line, VEC_NO });
    const unique_id = pci.uniqueId(bus, slot, function);
    //int.addISR(interrupt_line, .{ .unique_id = unique_id, .func = handleInterrupt }) catch |err| {
    int.addISR(@intCast(VEC_NO), .{ .unique_id = unique_id, .func = handleInterrupt }) catch |err| {
        log.err("Failed to add NVMe interrupt handler: {}", .{err});
    };

    // Allocate one prp1 for all commands
    const prp1 = heap.page_allocator.alloc(u8, pmm.page_size) catch |err| {
        log.err("Failed to allocate memory for identify command: {}", .{err});
        return;
    };
    @memset(prp1, 0);
    defer heap.page_allocator.free(prp1);
    const prp1_phys = paging.physFromPtr(prp1.ptr) catch |err| {
        log.err("Failed to get physical address of identify command: {}", .{err});
        return;
    };
    _ = executeAdminCommand(bar, &drive, @bitCast(IdentifyCommand{
        .cdw0 = .{
            .opc = .identify,
            .cid = 0x01, //our id
        },
        .dptr = .{
            .prp = .{
                .prp1 = prp1_phys,
                .prp2 = 0, //we need only one page
            },
        },
        .cns = 0x01,
    })) catch |err| {
        log.err("Failed to execute Identify Command(cns:0x01): {}", .{err});
        return;
    };

    const identify_info: *const Identify0x01Info = @ptrCast(@alignCast(prp1));
    log.info("Identify Controller Data Structure(cns: 0x01): {}", .{identify_info.*});
    if (identify_info.cntrltype != @intFromEnum(ControllerType.io_controller)) {
        log.err("Unsupported NVMe controller type: {}", .{identify_info.cntrltype});
        return;
    }

    drive.mdts_bytes = math.pow(u32, 2, 12 + cc.mps + identify_info.mdts);
    log.info("MDTS in kbytes: {}", .{drive.mdts_bytes / 1024});

    // I/O Command Set specific initialization

    //Reusing prp1
    @memset(prp1, 0);
    _ = executeAdminCommand(bar, &drive, @bitCast(IdentifyCommand{
        .cdw0 = .{
            .opc = .identify,
            .cid = 0x02, //our id
        },
        .dptr = .{
            .prp = .{
                .prp1 = prp1_phys,
            },
        },
        .cns = 0x1c,
    })) catch |err| {
        log.err("Failed to execute Identify Command(cns:0x1c): {}", .{err});
        return;
    };

    const io_command_set_combination_lst: *const [512]Identify0x1cCommandSetVector = @ptrCast(@alignCast(prp1));
    //TODO: find only one command set vector combination (comman set with specific ), that's not true cause there could be more than one
    var cmd_set_cmb: Identify0x1cCommandSetVector = undefined; //we choose the first combination
    const cs_idx: u9 = blk: {
        for (io_command_set_combination_lst, 0..) |cs, i| {
            //stop on first non-zero command set
            log.info("Identify I/O Command Set Combination(0x1c): idx:{d}: val:{}", .{ i, cs });
            if (cs.nvmcs != 0 and (cs.kvcs != 0 or cs.zncs != 0)) {
                cmd_set_cmb = cs;
                break :blk @intCast(i);
            }
        } else {
            log.err("No valid Identify I/O Command Set Combination(0x1c) found", .{});
            return;
        }
    };

    // Set I/O Command Set Profile with Command Set Combination index
    @memset(prp1, 0);
    _ = executeAdminCommand(bar, &drive, @bitCast(SetFeatures0x19Command{
        .cdw0 = .{
            .opc = .set_features,
            .cid = 0x03, //our id
        },
        .dptr = .{
            .prp = .{
                .prp1 = prp1_phys,
            },
        },
        .fid = 0x19, //I/O Command Set Profile
        .sv = 0, //do not save
        .iosci = cs_idx,
    })) catch |err| {
        log.err("Failed to execute Set Features Command(fid: 0x19): {}", .{err});
        return;
    };

    // const fields = @typeInfo(Identify0x1cCommandSetVector).Struct.fields;
    // inline for (fields, 0..) |field, i| {
    //     log.info("Identify I/O Command Set Combination(0x1c): name:{s} idx:{d}, value:{}", .{ field.name, i, @field(cmd_set_cmb, field.name) });
    // }

    // I/O Command Set specific Active Namespace ID list (CNS 07h)
    // Each Command Set may have a list of active Namespace IDs
    for ([_]u1{ cmd_set_cmb.nvmcs, cmd_set_cmb.kvcs, cmd_set_cmb.zncs }, 0..) |csi, i| {
        if (csi == 0) continue;
        log.info("I/O Command Set specific Active Namespace ID list(0x07): command set idx:{d} -> csi:{d}", .{ i, csi });
        @memset(prp1, 0);
        _ = executeAdminCommand(bar, &drive, @bitCast(IdentifyCommand{
            .cdw0 = .{
                .opc = .identify,
                .cid = 0x04, //our id
            },
            .dptr = .{
                .prp = .{
                    .prp1 = prp1_phys,
                },
            },
            .cns = 0x07,
            .csi = @intCast(i),
        })) catch |err| {
            log.err("Failed to execute Identify Command(cns:0x07): {}", .{err});
            return;
        };

        const io_command_set_active_nsid_lst: *const [1024]NSID = @ptrCast(@alignCast(prp1));
        for (io_command_set_active_nsid_lst, 0..) |nsid, j| {
            //stop on first non-zero nsid
            //log.info("Identify I/O Command Set Active Namespace ID List(0x07): command set idx:{d} nsid idx:{d}, nsid:{d}", .{ i, j, nsid });
            if (nsid != 0) {
                log.info("Identify I/O Command Set Active Namespace ID List(0x07): command set idx:{d} nsid idx:{d}, nsid:{d}", .{ i, j, nsid });

                // Identify Namespace Data Structure (CNS 0x00)
                @memset(prp1, 0);
                _ = executeAdminCommand(bar, &drive, @bitCast(IdentifyCommand{
                    .cdw0 = .{
                        .opc = .identify,
                        .cid = 0x05, //our id
                    },
                    .nsid = nsid,
                    .dptr = .{
                        .prp = .{
                            .prp1 = prp1_phys,
                        },
                    },
                    .cns = 0x00,
                })) catch |err| {
                    log.warn("Identify Command(cns:0x00) failed with error: {}", .{err});
                    continue; // we do not return as we want to continue with other namespaces
                };

                const ns_info: *const Identify0x00Info = @ptrCast(@alignCast(prp1));
                log.info("Identify Namespace Data Structure(cns: 0x00): nsid:{d}, info:{}", .{ nsid, ns_info.* });

                log.debug("vs: {}", .{vs});
                if (vs.mjn == 2) {
                    // TODO: see section 8.b in the 3.5.1 Memory-based Transport Controller Initialization chapter
                    // TODO: implement it when qemu is ready to handle with NVMe v2.0

                    log.debug("vs2: {}", .{vs});
                    // CNS 05h: I/O Command Set specific Identify Namespace data structure
                    @memset(prp1, 0);
                    _ = executeAdminCommand(bar, &drive, @bitCast(IdentifyCommand{
                        .cdw0 = .{
                            .opc = .identify,
                            .cid = 0x06, //our id
                        },
                        .nsid = nsid,
                        .dptr = .{
                            .prp = .{
                                .prp1 = prp1_phys,
                            },
                        },
                        .cns = 0x05,
                        .csi = 0x00, //see NVMe NVM Command Set Specification
                    })) catch |err| {
                        log.err("Failed to execute Identify Command(cns:0x05): {}", .{err});
                        return;
                    };

                    const ns_io_info: *const Identify0x05Info = @ptrCast(@alignCast(prp1));
                    log.info("Identify I/O Command Set specific Identify Namespace data structure for the specified NSID (cns: 0x05): nsid:{d}, info:{}", .{ nsid, ns_io_info.* });

                    // CNS 06h: I/O Command Set specific Identify Controller data structure
                    @memset(prp1, 0);
                    _ = executeAdminCommand(bar, &drive, @bitCast(IdentifyCommand{
                        .cdw0 = .{
                            .opc = .identify,
                            .cid = 0x07, //our id
                        },
                        .nsid = nsid,
                        .dptr = .{
                            .prp = .{
                                .prp1 = prp1_phys,
                            },
                        },
                        .cns = 0x06,
                        .csi = 0x00, //see NVMe NVM Command Set Specification
                    })) catch |err| {
                        log.err("Failed to execute Identify Command(cns:0x06): {}", .{err});
                        return;
                    };

                    const ns_ctrl_info: *const Identify0x06Info = @ptrCast(@alignCast(prp1));
                    log.info("Identify I/O Command Set specific Identify Controller data structure for the specified NSID (cns: 0x06): nsid:{d}, info:{}", .{ nsid, ns_ctrl_info.* });

                    // CNS 08h: I/O Command Set independent Identify Namespace data structure
                    @memset(prp1, 0);
                    _ = executeAdminCommand(bar, &drive, @bitCast(IdentifyCommand{
                        .cdw0 = .{
                            .opc = .identify,
                            .cid = 0x08, //our id
                        },
                        .nsid = nsid,
                        //.nsid = 0xffffffff, //0xffffffff means all namespaces
                        .dptr = .{
                            .prp = .{
                                .prp1 = prp1_phys,
                            },
                        },
                        .cns = 0x08,
                    })) catch |err| {
                        log.err("Failed to execute Identify Command(cns:0x08): {}", .{err});
                        return;
                    };

                    const ns_indep_info: *const Identify0x08Info = @ptrCast(@alignCast(prp1));
                    log.info("Identify I/O Command Set Independent Identify Namespace data structure for the specified NSID (cns: 0x08): nsid:{d}, info:{}", .{ nsid, ns_indep_info.* });
                } //vs.mjr==2
            }
        } // nsids

        // Set I/O Command Set Profile with Command Set Combination index
        @memset(prp1, 0);
        const get_features_0x07_res = executeAdminCommand(bar, &drive, @bitCast(GetFeaturesCommand{
            .cdw0 = .{
                .opc = .get_features,
                .cid = 0x09, //our id
            },
            .dptr = .{
                .prp = .{
                    .prp1 = prp1_phys,
                },
            },
            .fid = 0x07, //I/O Command Set Profile
            .sel = .default,
        })) catch |err| {
            log.err("Failed to execute Get Features Command(fid: 0x07): {}", .{err});
            return;
        };

        const supported_ncqr: u16 = @truncate(get_features_0x07_res.cmd_res0 >> 16);
        const supported_nsqr: u16 = @truncate(get_features_0x07_res.cmd_res0);
        log.info("Get Features Command(fid: 0x07): Default Number Of Completion/Submission Queues: {d}/{d}", .{ supported_ncqr, supported_nsqr });

        if (drive.ncqr > supported_ncqr or drive.nsqr > supported_nsqr) {
            log.err("Requested number of completion/submission queues is not supported", .{});
        }

        // log intms and intmc registers
        log.info("NVMe INTMS Register: 0b{b:0>32}, INTMC Register: 0b{b:0>32}", .{ intms_reg_ptr.*, intmc_reg_ptr.* });

        //set bit 42 to 1 to enable interrupt
        intmc_reg_ptr.* = 0x00000400;
        log.info("NVMe INTMS Register post-modification: 0b{b:0>32}", .{intmc_reg_ptr.*});

        // Create I/O Completion Queue -  TODO:  we can create up to ncqr, and nsqr queues, but for not we create only one

        const IS_MASKED = int.isIRQMasked(0x0a);
        switch (IS_MASKED) {
            false => {
                log.info("NVMe interrupt line: {x}, vector number: 0x{x}, is masked: {}", .{ interrupt_line, VEC_NO, IS_MASKED });
                int.triggerInterrupt(0x2a);
            },
            true => log.err("NVMe interrupt line: {x}, vector number: 0x{x}, is masked: {}", .{ interrupt_line, VEC_NO, IS_MASKED }),
        }

        for (&drive.iocq, 1..) |*cq, cq_id| {
            cq.* = .{};

            cq.entries = heap.page_allocator.alloc(CQEntry, nvme_ncqr) catch |err| {
                log.err("Failed to allocate memory for completion queue entries: {}", .{err});
                return;
            };

            const cq_phys = paging.physFromPtr(drive.cqa.ptr) catch |err| {
                log.err("Failed to get physical address of I/O Completion Queue: {}", .{err});
                return;
            };
            @memset(cq.entries, .{});

            const create_iocq_res = executeAdminCommand(bar, &drive, @bitCast(CreateIOCQCommand{
                .cdw0 = .{
                    .opc = .create_io_cq,
                    .cid = @intCast(0x100 + cq_id), //our id
                },
                .dptr = .{
                    .prp = .{
                        .prp1 = cq_phys,
                    },
                },
                .qsize = nvme_iocqs,
                .qid = @intCast(cq_id), // we use only one queue
                .pc = true, // physically contiguous - the buddy allocator allocs memory in physically contiguous blocks
                .ien = true, // interrupt enabled
                .iv = VEC_NO,
            })) catch |err| {
                log.err("Failed to execute Create CQ Command: {}", .{err});
                return;
            };

            cq.head_dbl = @ptrFromInt(doorbell_base + doorbell_size * (2 * cq_id + 1));

            _ = create_iocq_res; //TODO
        }

        //for (drive.iosq, 0..) |sq, sq_idx| {}
    }
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

    heap.page_allocator.free(drive.sqa);
    heap.page_allocator.free(drive.cqa);
}

// --- helper functions ---

fn toggleController(bar: pci.BAR, enable: bool) void {
    var cc = readRegister(CCRegister, bar, .cc);
    log.info("CC register before toggle: {}", .{cc});
    cc.en = if (enable) 1 else 0;
    writeRegister(CCRegister, bar, .cc, cc);

    cc = readRegister(CCRegister, bar, .cc);
    log.info("CC register after toggle: {}", .{cc});

    while (readRegister(CSTSRegister, bar, .csts).rdy != @intFromBool(enable)) {}

    log.info("NVMe controller is {s}", .{if (enable) "enabled" else "disabled"});
}

fn disableController(bar: pci.BAR) void {
    toggleController(bar, false);
}

fn enableController(bar: pci.BAR) void {
    toggleController(bar, true);
}

fn executeAdminCommand(bar: pci.BAR, drv: *Drive, cmd: SQEntry) NVMeError!CQEntry {
    drv.sqa[drv.sqa_tail_pos] = cmd;

    drv.sqa_tail_pos += 1;
    if (drv.sqa_tail_pos >= drv.sqa.len) drv.sqa_tail_pos = 0;

    const cqa_entry_ptr = &drv.cqa[drv.cqa_head_pos];

    // press the doorbell
    drv.sqa_tail_dbl.* = drv.sqa_tail_pos;

    while (cqa_entry_ptr.phase != drv.expected_phase) {
        const csts = readRegister(CSTSRegister, bar, .csts);
        if (csts.cfs == 1) {
            log.err("Command failed", .{});
            return NVMeError.InvalidCommand;
        }
        if (csts.shst != 0) {
            if (csts.st == 1) log.err("NVE Subsystem is in shutdown state", .{}) else log.err("Controller is in shutdown state", .{});

            log.err("Controller is in shutdown state", .{});
            return NVMeError.InvalidCommand;
        }
        if (csts.nssro == 1) {
            log.err("Controller is not ready", .{});
            return NVMeError.InvalidCommand;
        }
        if (csts.pp == 1) {
            log.err("Controller is in paused state", .{});
            return NVMeError.InvalidCommand;
        }
    }

    drv.sqa_header_pos = cqa_entry_ptr.sq_header_pos; //the controller position retuned in CQEntry as sq_header_pos

    drv.cqa_head_pos += 1;
    if (drv.cqa_head_pos >= drv.cqa.len) {
        drv.cqa_head_pos = 0;
        // every new cycle we need to toggle the phase
        drv.expected_phase = ~drv.expected_phase;
    }

    //press the doorbell
    drv.cqa_head_dbl.* = drv.cqa_head_pos;

    const cdw0: *const CDW0 = @ptrCast(@alignCast(&cmd));
    if (cdw0.cid == cqa_entry_ptr.sq_id) return NVMeError.InvalidCommandSequence;

    if (cqa_entry_ptr.status.sc != 0) {
        log.err("Admin command failed: {}", .{cqa_entry_ptr.*});
        return NVMeError.AdminCommandFailed;
    }

    log.info("Admin command executed successfully: CQEntry = {}", .{cqa_entry_ptr.*});
    return cqa_entry_ptr.*;
}
