const std = @import("std");
const log = std.log.scoped(.nvme);
const Pcie = @import("mod.zig").Pcie;
const paging = @import("../paging.zig");
const int = @import("../int.zig");
const pmm = @import("../mem/pmm.zig");
const heap = @import("../mem/heap.zig").heap;
const math = std.math;
const cpu = @import("../cpu.zig");
const apic_test = @import("../arch/x86_64/apic.zig");

const Device = @import("mod.zig").Device;
const Driver = @import("Driver.zig");
const NvmeDevice = @import("mod.zig").NvmeDevice;

const msix = @import("nvme/msix.zig");
const ctrl = @import("nvme/controller.zig");
const regs = @import("nvme/registers.zig");
pub const q = @import("nvme/queue.zig");

const nvme_class_code = 0x01;
const nvme_subclass = 0x08;
const nvme_prog_if = 0x02;

const nvme_iosqs = 0x8; //submisstion queue size(length)
const nvme_iocqs = 0x8; //completion queue size
const nvme_ioacqs = 0x2; //admin completion queue size
const nvme_ioasqs = 0x2; //admin submission queue size

const tmp_msix_table_idx = 0x01;
const tmp_irq = 0x33;

//const nvme_ncqr = 0x1 + 0x1; //number of completion queues requested (+1 is admin cq)
//const nvme_nsqr = nvme_ncqr; //number of submission queues requested

const NvmeDriver = @This();

//Fields
alloctr: std.mem.Allocator,

const NvmeError = error{ InvalidCommand, InvalidCommandSequence, AdminCommandNoData, AdminCommandFailed, MsiXMisconfigured, InvalidLBA, InvalidNsid, IONvmReadFailed };

const ControllerType = enum(u8) {
    io_controller = 1,
    discovery_controller = 2,
    admin_controller = 3,
};

const AdminOpcode = enum(u8) {
    identify = 0x06,
    abort = 0x0c,
    set_features = 0x09,
    get_features = 0x0a,
    create_io_sq = 0x01,
    delete_io_sq = 0x00,
    create_io_cq = 0x05,
    delete_io_cq = 0x04,
};

const IoNvmOpcode = enum(u8) {
    write = 0x01,
    read = 0x02,
};

const NsId = u32;

fn GenNCDw0(OpcodeType: type) type {
    return packed struct(u32) {
        opc: OpcodeType,
        fuse: u2 = 0, //0 for nromal operation
        rsvd: u4 = 0,
        psdt: u2 = 0, //0 for PRP tranfer
        cid: u16,
    };
}

const AdminCDw0 = GenNCDw0(AdminOpcode);
const IoNvmCDw0 = GenNCDw0(IoNvmOpcode);

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

const IdentifyCommand = packed struct(u512) {
    cdw0: AdminCDw0, //00:03 byte
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

const GetSetFeaturesCommand = packed union {
    const FeatureSelect = enum(u3) {
        current = 0b000,
        default = 0b001,
        saved = 0b010,
        supported_capabilities = 0b011,
    };
    get_number_of_queues: packed struct(u512) {
        cdw0: AdminCDw0, //cdw0,
        ignrd_a: u32 = 0, //cdw1,
        ignrd_b: u32 = 0, //cdw2
        ignrd_c: u32 = 0, //cdw3
        ignrd_e: u64 = 0, //cdw4, cdw5
        ignrd_f: u128 = 0, //cdw6, cdw7, cdw8,cdw9
        fid: u8 = 0x07, //cdw10 - Feature Identifier
        sel: FeatureSelect, //cdw10 - Select
        rsrv_a: u21 = 0, //11-31 in cdw10 - Reserved
        ignrd_g: u32 = 0, //32-63 in cdw11 - I/O Command Set Combination Index
        ignrd_h: u32 = 0, //48-52 in cdw12
        ignrd_i: u32 = 0, //52-55 in cdw13
        ignrd_j: u32 = 0, //56-59 in cdw14
        ignrd_k: u32 = 0, //60-63 in cdw15
    },
    set_number_of_queues: packed struct(u512) {
        cdw0: AdminCDw0, //cdw0,
        ignrd_a: u32 = 0, //cdw1,
        ignrd_b: u32 = 0, //cdw2
        ignrd_c: u32 = 0, //cdw3
        ignrd_e: u64 = 0, //cdw4, cdw5
        ignrd_f: u128 = 0, //cdw6, cdw7, cdw8,cdw10
        fid: u8 = 0x07, //cdw10 - Feature Identifier
        rsrvd_a: u24 = 0, //cdw10
        ncqr: u16, //cdw11 - I/O Command Set Combination Index
        nsqr: u16 = 0, // cdw11
        ignrd_g: u32 = 0, //cdw12
        ignrd_h: u32 = 0, //cdw13
        ignrd_i: u32 = 0, //cdw14
        ignrd_j: u32 = 0, //cdw15
    },
    set_io_command_profile: packed struct(u512) {
        cdw0: AdminCDw0, //cdw0
        ignrd_a: u32 = 0, //cdw1
        ignrd_b: u32 = 0, //cdw2
        ignrd_c: u32 = 0, //cdw3
        ignrd_e: u64 = 0, //cdw5
        dptr: DataPointer, //cdw6, cdw7, cdw8,cdw9
        fid: u8 = 0x19, //cdw10 - Feature Identifier
        rsrv_a: u23 = 0, //cdw10
        sv: u1, //cdw10 - Save
        iosci: u9, //cdw11 - I/O Command Set Combination Index
        rsrvd_b: u23 = 0, //cdw11
        ignrd_f: u32 = 0, //cdw12
        ignrd_g: u32 = 0, //cdw13
        uuid: u7 = 0, //cdw14 - UUID
        rsrvd_c: u25 = 0, //cdw14
        ignrd_h: u32 = 0, //cdw15
    },
    get_interrupt_coalescing: packed struct(u512) {
        cdw0: AdminCDw0, //cdw0
        ignrd_a: u32 = 0, //cdw1
        ignrd_b: u32 = 0, //cdw2
        ignrd_c: u32 = 0, //cdw3
        ignrd_e: u64 = 0, //cdw5
        ignrd_f: u128 = 0, //cdw6, cdw7, cdw8,cdw9
        fid: u8 = 0x08, //cdw10 - Feature Identifier
        sel: FeatureSelect, //cdw10 - Select
        rsrv_a: u21 = 0, //cdw10
        ignrd_g: u32 = 0, //cdw11
        ignrd_h: u32 = 0, //cdw12
        ignrd_i: u32 = 0, //cdw13
        ignrd_j: u32 = 0, //cdw14
        ignrd_k: u32 = 0, //cdw15
    },
    SetInterruptCoalescing: packed struct(u512) {
        cdw0: AdminCDw0, //cdw0
        ignrd_a: u32 = 0, //cdw1
        ignrd_b: u32 = 0, //cdw2
        ignrd_c: u32 = 0, //cdw3
        ignrd_e: u64 = 0, //cdw5
        ignrd_f: u128 = 0, //cdw6, cdw7, cdw8,cdw9
        fid: u8 = 0x08, //cdw10 - Feature Identifier
        rsrv_a: u24 = 0, //cdw10
        thr: u8, //cdw11 - Aggregation Threshold
        time: u8, //cdw11 - Aggregation Time
        rsrv_b: u16 = 0, //cdw11
        ignrd_g: u32 = 0, //cdw12
        ignrd_h: u32 = 0, //cdw13
        ignrd_i: u32 = 0, //cdw14
        ignrd_j: u32 = 0, //cdw15
    },
};

const IoNvmCommandSetCommand = packed union {
    const DatasetManagement = packed struct(u8) { access_frequency: u4, access_latency: u2, sequential_request: u1, incompressible: u1 };
    read: packed struct(u512) {
        cdw0: IoNvmCDw0, //cdw0 - 00:03 byte
        nsid: NsId, //cdw1 - 04:07 byte - nsid
        elbst_eilbst_a: u48, //cdw2,cdw3 - Expected Logical Block Storage Tag and Expected Initial Logical Block Storage Tag
        rsrv_a: u16 = 0, //cdw3
        mptr: u64, //cdw4,cdw5 - Metadata Pointer
        dptr: DataPointer, //cdw6,cdw7,cdw8,cdw9 - Data Pointer
        slba: u64, //cdw10,cdw11 - Starting LBA
        nlb: u16, //cdw12 - Number of Logical Blocks
        rsrv_b: u8 = 0, //cdw12 - Reserved
        stc: u1, //cdw12 - Storage Tag Check
        rsrv_c: u1 = 0, //cdw12 - Reserved
        prinfo: u4, //cdw12 - Protection Information Field
        fua: u1, //cdw12 - Force Unit Access
        lr: u1, //cdw12 - Limited Retry
        dsm: DatasetManagement, //cdw13 - Dataset Management
        rsrv_d: u24 = 0, //cdw13 - Reserved
        elbst_eilbst_b: u32, //cdw14 - Expected Logical Block Storage Tag and Expected Initial Logical Block Storage Tag
        elbat: u16, //cdw15 - Expected Logical Block Application Tag
        elbatm: u16, //cdw15 - Expected Logical Block Application Tag Mask
    },
    write: packed struct(u512) {
        cdw0: IoNvmCDw0, //cdw0
        nsid: NsId, //cdw1
        lbst_ilbst_a: u48, //cdw2,cdw3
        rsrv_a: u16 = 0, //cdw3
        mptr: u64, //cdw4,cdw5
        dptr: DataPointer, //cdw6,cdw7,cdw8,cdw9
        slba: u64, //cdw10,cdw11
        nlb: u16, //cdw12
        rsrv_b: u4 = 0, //cdw12
        dtype: u4, //cdw12 - Directive type
        stc: u1, //cdw12 - Storage Tag Check
        rsrv_c: u1 = 0, //cdw12
        prinfo: u4, //cdw12 - Protection Information Field
        fua: u1, //cdw12 - Force Unit Access
        lr: u1, //cdw12 - Limited Retry
        dsm: DatasetManagement, //cdw13 - Dataset Management
        rsrv_d: u8 = 0, //cdw13
        dspec: u16, //cdw14 - Directive Specific
        lbst_ilbst_b: u32, //cdw15
        lbat: u16, //cdw15 - Logical Block Application Tag
        lbatm: u16, //cdw15 - Logical Block Application Tag Mask
    },
};

const IoQueueCommand = packed union {
    create_completion_queue: packed struct(u512) {
        cdw0: AdminCDw0, //cdw0
        ignrd_a: u32 = 0, // nsid
        ignrd_b: u32 = 0, //cdw2
        ignrd_c: u32 = 0, //cdw3
        ignrd_e: u64 = 0, // cdw4,cdw5
        dptr: DataPointer, //cdw6, cdw7, cdw8, cdw9
        qid: u16, //cdw10 - Queue Identifier
        qsize: u16, //cdw10 - Queue Size
        pc: bool, //cdw11 - Physically Contiguous
        ien: bool, //cdw11 - Interrupt Enable
        rsrvd_a: u14 = 0, // cdw11
        iv: u16, //cdw11- Interrupt Vector
        ignrd_f: u32 = 0, //cdw12
        ignrd_g: u32 = 0, //cdw13
        ignrd_h: u32 = 0, //cdw14
        ignrd_i: u32 = 0, //cdw15
    },
    delete_queue: packed struct(u512) {
        cdw0: AdminCDw0, //cdw0
        ignrd_a: u32 = 0, //nsid in cdw1
        ignrd_b: u32 = 0, //cdw2
        ignrd_c: u32 = 0, //cdw3
        ignrd_e: u64 = 0, //mptr
        ignrd_f: u128 = 0, //prp1, prp2
        qid: u16, //Queue Identifier
        rsrvd: u16 = 0, //cdw10
        ignrd_h: u32 = 0, //cdw11
        ignrd_i: u32 = 0, //cdw12
        ignrd_j: u32 = 0, //cdw13
        ignrd_k: u32 = 0, //cdw14
        ignrd_l: u32 = 0, //cdw15
    },
    create_submission_queue: packed struct(u512) {
        cdw0: AdminCDw0, //cdw0
        ignrd_a: u32 = 0, //nsid - cdw1
        ignrd_b: u32 = 0, //cdw2
        ignrd_c: u32 = 0, //cdw3
        ignrd_e: u64 = 0, //mptr - cdw4,cwd5
        dptr: DataPointer, //prp1, prp2 - cdw6, cdw7, cdw8, cdw9
        qid: u16, //cdw10 - Queue Identifier
        qsize: u16, //cdw10 - Queue Size
        // cqid: u16, //cdw11 - Completion Queue Identifier
        pc: bool, //cdw11 - Physically Contiguous
        qprio: enum(u2) {
            urgent = 0b00,
            high = 0b01,
            medium = 0b10,
            low = 0b11,
        }, //cdw11 - Queue Priority
        rsrvd_a: u13 = 0, //cdw11
        cqid: u16, //cdw11 - Completion Queue Identifier
        nvmsetid: u16, //cdw12 - NVM Set Identifier
        rsrvd_b: u16 = 0, //cdw12
        ignrd_f: u32 = 0, //cdw13
        ignrd_h: u32 = 0, //cdw14
        ignrd_i: u32 = 0, //cdw15
    },
};

const LBAFormatInfo = packed struct(u32) {
    ms: u16, //0-15 - Metadata Size
    lbads: u8, //4-7 - LBA Data Size
    rp: u2, //8 - Relative Performance
    rsvd: u6, //9-11
};

const Identify0x00Info = extern struct {
    nsize: u64, //8bytes - Namespace Size - host can't base on this value
    ncap: u64, //8bytes - Namespace Capacity - host can you this value
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

const NsInfo = Identify0x00Info; //alias for Identify0x00Info

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

pub const NsInfoMap = std.AutoHashMap(u32, NsInfo);

// const Device = struct {
//     const nvme_ncqr = 0x2; //number of completion queues requested (+1 is admin cq)
//     const nvme_nsqr = nvme_ncqr; //number of submission queues requested
//
//     //-    sqa: []volatile SQEntry = undefined,
//     //-    cqa: []volatile CQEntry = undefined,
//     //sq: []volatile SQEntry = undefined,
//     //cq: []volatile CQEntry = undefined,
//
//     //-   sqa_tail_pos: u32 = 0, // private counter to keep track and update sqa_tail_dbl
//     //-   sqa_header_pos: u32 = 0, //contoller position retuned in CQEntry as sq_header_pos
//     //-   sqa_tail_dbl: *volatile u32 = undefined, //each doorbell value is u32, minmal doorbell stride is 4 (2^(2+CAP.DSTRD))
//     //-   cqa_head_pos: u32 = 0 ,
//     //-   cqa_head_dbl: *volatile u32 = undefined, //each doorbell value is u32, minmal doorbell stride is 4 (2^(2+CAP.DSTRD))
//
//     //sq_tail_pos: u32 = 0, //private counter to keep track and update sq_tail_dbl
//     //sq_tail_dbl: *volatile u32 = undefined,
//     //cq_head_dbl: *volatile u32 = undefined,
//
//     //-acq: Queue(CQEntry) = undefined,
//     //-asq: Queue(SQEntry) = undefined,
//
//     bar: Pcie.Bar = undefined,
//     msix_cap: Pcie.MsixCap = undefined,
//
//     //expected_phase: u1 = 1, //private counter to keep track of the expected phase
//     mdts_bytes: u32 = 0, // Maximum Data Transfer Size in bytes
//
//     ncqr: u16 = nvme_ncqr, //number of completion queues requested - TODO only one cq now
//     nsqr: u16 = nvme_nsqr, //number of submission queues requested - TODO only one sq now
//
//     cq: [nvme_ncqr]Queue(CQEntry) = undefined, //+1 for admin cq
//     //cq: [nvme_ncqr + 1]Queue(CQEntry) = undefined, //+1 for admin
//     sq: [nvme_nsqr]Queue(SQEntry) = undefined, //+1 for admin sq
//
//     //slice of NsInfo
//     ns_info_map: NsInfoMap = undefined,
//
//     mutex: bool = false,
// };

//pub var drive: Device = undefined; //TODO only one drive now, make not public

/// Devicer interface function to match the driver with the device
pub fn probe(_: *anyopaque, probe_ctx: *const anyopaque) bool {
    const pcie_ctx: *const Pcie.PcieProbeContext = @ptrCast(@alignCast(probe_ctx));
    return pcie_ctx.class_code == nvme_class_code and pcie_ctx.subclass == nvme_subclass and pcie_ctx.prog_if == nvme_prog_if;
}

/// Devicer interface function
pub fn setup(ctx: *anyopaque, device: *Device) !void {
    const self: *NvmeDriver = @ptrCast(@alignCast(ctx));
    device.driver = self.driver();
    device.spec = .{ .block_device = .{ .nvme = .{ .base = device } } };

    // now we can access the NVMe device
    const dev = &device.spec.block_device.nvme;
    const addr = device.addr.pcie;

    //const pcie_version = try Pcie.readPcieVersion(function, slot, bus); //we need PCIe version 2.0 at least
    const pcie_version = try Pcie.readCapability(Pcie.VersionCap, addr);
    log.info("PCIe version: {}", .{pcie_version});

    if (pcie_version.major < 2) {
        log.err("Unsupported PCIe version: {}.{}", .{ pcie_version.major, pcie_version.minor });
        return;
    }

    //read MSI capability to check if's disabled or enabled
    const msi_cap: ?Pcie.MsiCap = Pcie.readCapability(Pcie.MsiCap, addr) catch |err| blk: {
        log.err("Failed to read MSI capability: {}", .{err});
        break :blk null;
    };
    log.debug("MSI capability: {?}", .{msi_cap});

    dev.msix_cap = try Pcie.readCapability(Pcie.MsixCap, addr);
    log.debug("MSI-X capability pre-modification: {}", .{dev.msix_cap});

    if (dev.msix_cap.tbir != 0) return NvmeError.MsiXMisconfigured; //TODO: it should work on any of the bar but for now we support only bar0

    //enable MSI-X
    dev.msix_cap.mc.mxe = true;
    try Pcie.writeCapability(Pcie.MsixCap, dev.msix_cap, addr);

    dev.msix_cap = try Pcie.readCapability(Pcie.MsixCap, addr); //TODO: could be removed
    log.info("MSI-X capability post-modification: {}", .{dev.msix_cap});

    //- var pci_cmd_reg = Pcie.readRegisterWithArgs(u16, .command, function, slot, bus);
    //disable interrupts while using MSI-X
    //-pci_cmd_reg |= 1 << 15;
    //-Pcie.writeRegisterWithArgs(u16, .command, function, slot, bus, pci_cmd_reg);
    // const VEC_NO: u16 = 0x20 + interrupt_line; //TODO: we need MSI/MSI-X support first - PIC does not work here

    dev.ns_info_map = NsInfoMap.init(device.alloctr);
    dev.bar = Pcie.readBarWithArgs(.bar0, addr);

    // Initialize queues to the default values
    for (&dev.sq) |*sq| {
        //Add code here if needed
        sq.* = .{};
    }
    for (&dev.cq) |*cq| {
        //Add code here if needed
        cq.* = .{};
    }

    //MSI-X
    msix.configureMsix(dev, tmp_msix_table_idx, tmp_irq) catch |err| {
        log.err("Failed to configure MSI-X: {}", .{err});
    };
    // const unique_id = Pcie.uniqueId(bus, slot, function);
    // int.addISR(@intCast(0x33), .{ .unique_id = unique_id, .func = handleInterrupt }) catch |err| {
    //     log.err("Failed to add NVMe interrupt handler: {}", .{err});
    // };
    // Pcie.addMsixMessageTableEntry(dev.msix_cap, dev.bar, 0x9, 0x33); //add 0x31 at 0x01 offset
    //
    // inline for (0x0.., 0..64) |vec_no, ivt_idx| {
    //     Pcie.addMsixMessageTableEntry(dev.msix_cap, dev.bar, @intCast(ivt_idx), @intCast(vec_no)); //add 0x31 at 0x01 offset
    //     int.addISR(
    //         @intCast(vec_no),
    //         .{ .unique_id = @intCast(ivt_idx + 100), .func = int.bindSampleISR(@intCast(vec_no)) },
    //     ) catch |err| {
    //         log.err("Failed to add NVMe interrupt handler: {}", .{err});
    //     };
    // }

    //log pending bit in MSI-X
    const pending_bit = Pcie.readMsixPendingBitArrayBit(dev.msix_cap, dev.bar, 0x0);
    log.info("MSI-X pending bit: {}", .{pending_bit});

    //  bus-mastering DMA, and memory space access in the PCI configuration space
    const command = Pcie.readRegisterWithArgs(u16, .command, addr);
    log.warn("PCI command register: 0b{b:0>16}", .{command});
    // Enable interrupts, bus-mastering DMA, and memory space access in the PCI configuration space for the function.
    Pcie.writeRegisterWithArgs(u16, .command, addr, command | 0b110);

    const virt = switch (dev.bar.address) {
        inline else => |phys| paging.virtFromMME(phys),
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

    const register_set_ptr: *volatile regs.RegisterSet = @ptrFromInt(virt);

    // Adjust if needed page PAT to write-through
    const size: usize = switch (dev.bar.size) {
        .as32 => dev.bar.size.as32,
        .as64 => dev.bar.size.as64,
    };

    //TODO uncomment this
    log.debug("Adjusting page area for NVMe BAR: {} size: {}", .{ virt, size });
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
        dev.bar,
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
    const vs = regs.readRegister(regs.VSRegister, dev.bar, .vs);
    log.info("NVMe controller version: {}.{}.{}", .{ vs.mjn, vs.mnr, vs.tet });

    // support only NVMe 1.4 and 2.0
    if (vs.mjn == 1 and vs.mnr < 4) {
        log.err("Unsupported NVMe controller major version:  {}.{}.{}", .{ vs.mjn, vs.mnr, vs.tet });
        return;
    }

    // Check if the controller supports NVM Command Set and Admin Command Set
    const cap = regs.readRegister(regs.CAPRegister, dev.bar, .cap);
    log.info("NVME CAP Register: {}", .{cap});
    if (cap.css.nvmcs == 0) {
        log.err("NVMe controller does not support NVM Command Set", .{});
        return;
    }

    if (cap.css.acs == 0) {
        log.err("NVMe controller does not support Admin Command Set", .{});
        return;
    }

    log.info("NVMe controller supports min/max memory page size: 2^(12 + cap.mpdmin:{d}) -> 2^(12 + cap.mpdmssx: {d}), 2^(12 + cc.mps: {d})", .{ cap.mpsmin, cap.mpsmax, @as(*regs.CCRegister, @ptrCast(@volatileCast(cc_reg_ptr))).*.mps });

    const sys_mps: u4 = @intCast(math.log2(pmm.page_size) - 12);
    if (cap.mpsmin < sys_mps or sys_mps > cap.mpsmax) {
        log.err("NVMe controller does not support the host's memory page size", .{});
        return;
    }

    // Reset the controllerg
    ctrl.disableController(dev.bar);

    // The host configures the Admin gQueue by setting the Admin Queue Attributes (AQA), Admin Submission Queue Base Address (ASQ), and Admin Completion Queue Base Address (ACQ) the appropriate values;
    //set AQA queue sizes
    var aqa = regs.readRegister(regs.AQARegister, dev.bar, .aqa);
    log.info("NVMe AQA Register pre-modification: {}", .{aqa});
    aqa.asqs = nvme_ioasqs;
    aqa.acqs = nvme_ioacqs;
    regs.writeRegister(regs.AQARegister, dev.bar, .aqa, aqa);
    aqa = regs.readRegister(regs.AQARegister, dev.bar, .aqa);
    log.info("NVMe AQA Register post-modification: {}", .{aqa});

    // ASQ and ACQ setup
    dev.sq[0].entries = heap.page_allocator.alloc(q.SQEntry, nvme_ioasqs) catch |err| {
        log.err("Failed to allocate memory for admin submission queue entries: {}", .{err});
        return;
    };
    defer heap.page_allocator.free(@volatileCast(dev.sq[0].entries));
    @memset(dev.sq[0].entries, 0);

    dev.cq[0].entries = heap.page_allocator.alloc(q.CQEntry, nvme_ioacqs) catch |err| {
        log.err("Failed to allocate memory for admin completion queue entries: {}", .{err});
        return;
    };
    defer heap.page_allocator.free(@volatileCast(dev.cq[0].entries));
    @memset(dev.cq[0].entries, .{});

    const sqa_phys = paging.physFromPtr(dev.sq[0].entries.ptr) catch |err| {
        log.err("Failed to get physical address of admin submission queue: {}", .{err});
        return;
    };
    const cqa_phys = paging.physFromPtr(dev.cq[0].entries.ptr) catch |err| {
        log.err("Failed to get physical address of admin completion queue: {}", .{err});
        return;
    };

    log.debug("ASQ: virt: {*}, phys:0x{x}; ACQ: virt:{*}, phys:0x{x}", .{ dev.sq[0].entries, sqa_phys, dev.cq[0].entries, cqa_phys });

    var asq = regs.readRegister(regs.ASQEntry, dev.bar, .asq);
    log.info("ASQ Register pre-modification: 0x{x}", .{@shlExact(asq.asqb, 12)});
    asq.asqb = @intCast(@shrExact(sqa_phys, 12)); // 4kB aligned
    regs.writeRegister(regs.ASQEntry, dev.bar, .asq, asq);
    asq = regs.readRegister(regs.ASQEntry, dev.bar, .asq);
    log.info("ASQ Register post-modification: 0x{x}", .{@shlExact(asq.asqb, 12)});

    var acq = regs.readRegister(regs.ACQEntry, dev.bar, .acq);
    log.info("ACQ Register pre-modification: 0x{x}", .{@shlExact(acq.acqb, 12)});
    acq.acqb = @intCast(@shrExact(cqa_phys, 12)); // 4kB aligned
    regs.writeRegister(regs.ACQEntry, dev.bar, .acq, acq);
    acq = regs.readRegister(regs.ACQEntry, dev.bar, .acq);
    log.info("ACQ Register post-modification: 0x{x}", .{@shlExact(acq.acqb, 12)});

    var cc = regs.readRegister(regs.CCRegister, dev.bar, .cc);
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
    regs.writeRegister(regs.CCRegister, dev.bar, .cc, cc);
    log.info("CC register post-modification: {}", .{regs.readRegister(regs.CCRegister, dev.bar, .cc)});

    ctrl.enableController(dev.bar);

    const doorbell_base: usize = virt + 0x1000;
    const doorbell_size = math.pow(u32, 2, 2 + cap.dstrd);
    dev.sq[0].tail_dbl = @ptrFromInt(doorbell_base + doorbell_size * 0);
    dev.cq[0].head_dbl = @ptrFromInt(doorbell_base + doorbell_size * 1);
    // for (&dev.iosq, 1..) |*sq, sq_dbl_idx| {
    //     sq.tail_dbl = @ptrFromInt(doorbell_base + doorbell_size * (2 * sq_dbl_idx));
    // }
    // for (&dev.iocq, 1..) |*cq, cq_dbl_idx| {
    //     cq.head_dbl = @ptrFromInt(doorbell_base + doorbell_size * (2 * cq_dbl_idx + 1));
    // }
    //
    //-log.info("NVMe interrupt line: {x}, vector number: 0x{x}", .{ interrupt_line, VEC_NO });
    //-const unique_id = pci.uniqueId(bus, slot, function);
    // int.addISR(@intCast(VEC_NO), .{ .unique_id = unique_id, .func = handleInterrupt }) catch |err| {
    //     log.err("Failed to add NVMe interrupt handler: {}", .{err});
    // };

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
    _ = executeAdminCommand(dev, @bitCast(IdentifyCommand{
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

    dev.mdts_bytes = math.pow(u32, 2, 12 + cc.mps + identify_info.mdts);
    log.info("MDTS in kbytes: {}", .{dev.mdts_bytes / 1024});

    // I/O Command Set specific initialization

    //Reusing prp1
    @memset(prp1, 0);
    _ = executeAdminCommand(dev, @bitCast(IdentifyCommand{
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
    _ = executeAdminCommand(dev, @bitCast(GetSetFeaturesCommand{
        .set_io_command_profile = .{
            .cdw0 = .{
                .opc = .set_features,
                .cid = 0x03, //our id
            },
            .dptr = .{
                .prp = .{
                    .prp1 = prp1_phys,
                },
            },
            .sv = 0, //do not save
            .iosci = cs_idx,
        },
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
        _ = executeAdminCommand(dev, @bitCast(IdentifyCommand{
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

        const io_command_set_active_nsid_lst: *const [1024]NsId = @ptrCast(@alignCast(prp1));
        for (io_command_set_active_nsid_lst, 0..) |nsid, j| {
            //stop on first non-zero nsid
            //log.info("Identify I/O Command Set Active Namespace ID List(0x07): command set idx:{d} nsid idx:{d}, nsid:{d}", .{ i, j, nsid });
            if (nsid != 0) {
                log.info("Identify I/O Command Set Active Namespace ID List(0x07): command set idx:{d} nsid idx:{d}, nsid:{d}", .{ i, j, nsid });

                // Identify Namespace Data Structure (CNS 0x00)
                @memset(prp1, 0);
                _ = executeAdminCommand(dev, @bitCast(IdentifyCommand{
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

                try dev.ns_info_map.put(nsid, ns_info.*);

                log.debug("vs: {}", .{vs});
                if (vs.mjn == 2) {
                    // TODO: see section 8.b in the 3.5.1 Memory-based Transport Controller Initialization chapter
                    // TODO: implement it when qemu is ready to handle with NVMe v2.0

                    log.debug("vs2: {}", .{vs});
                    // CNS 05h: I/O Command Set specific Identify Namespace data structure
                    @memset(prp1, 0);
                    _ = executeAdminCommand(dev, @bitCast(IdentifyCommand{
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
                    _ = executeAdminCommand(dev, @bitCast(IdentifyCommand{
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
                    _ = executeAdminCommand(dev, @bitCast(IdentifyCommand{
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
    }

    // Get current I/O number of completion/submission queues
    const get_current_number_of_queues_res = executeAdminCommand(dev, @bitCast(GetSetFeaturesCommand{
        .get_number_of_queues = .{
            .cdw0 = .{
                .opc = .get_features,
                .cid = 0x09, //our id
            },
            .sel = .current,
        },
    })) catch |err| {
        log.err("Failed to execute Get Features Command(fid: 0x07): {}", .{err});
        return;
    };

    const current_ncqr: u16 = @truncate((get_current_number_of_queues_res.cmd_res0 >> 16) + 1); //0-based value, so 0 means 1
    const current_nsqr: u16 = @truncate(get_current_number_of_queues_res.cmd_res0 + 1); //0-based value
    log.debug("Get Number of Queues: Current Number Of Completion/Submission Queues: {d}/{d}", .{ current_ncqr, current_nsqr });

    // Get default I/O number of completion/submission queues
    const get_default_number_of_queues_res = executeAdminCommand(dev, @bitCast(GetSetFeaturesCommand{
        .get_number_of_queues = .{
            .cdw0 = .{
                .opc = .get_features,
                .cid = 0x10, //our id
            },
            .sel = .default,
        },
    })) catch |err| {
        log.err("Failed to execute Get Features Command(fid: 0x07): {}", .{err});
        return;
    };

    const supported_ncqr: u16 = @truncate((get_default_number_of_queues_res.cmd_res0 >> 16) + 1); //0-based value, so 0 means 1
    const supported_nsqr: u16 = @truncate(get_default_number_of_queues_res.cmd_res0 + 1); //0-based value
    log.debug("Get Number of Queues Command: Default Number Of Completion/Submission Queues: {d}/{d}", .{ supported_ncqr, supported_nsqr });

    if (dev.ncqr > supported_ncqr or dev.nsqr > supported_nsqr) {
        log.err("Requested number of completion/submission queues is not supported", .{});
    }

    // log intms and intmc registers
    //-log.info("NVMe INTMS Register: 0b{b:0>32}, INTMC Register: 0b{b:0>32}", .{ intms_reg_ptr.*, intmc_reg_ptr.* });

    // we use MSI-X, so we should not touch it - Host software shall not access this property when configured for MSI-X; any accesses
    //when configured for MSI-X is undefined.  set bit 42 to 1 to enable interrupt
    //- intmc_reg_ptr.* = 0x00000400;
    //- log.info("NVMe INTMS Register post-modification: 0b{b:0>32}", .{intmc_reg_ptr.*});

    // Create I/O Completion Queue -  TODO:  we can create up to ncqr, and nsqr queues, but for not we create only one

    //- const IS_MASKED = int.isIRQMasked(0x0a);
    // switch (IS_MASKED) {
    //     false => {
    //         log.info("NVMe interrupt line: {x}, vector number: 0x{x}, is masked: {}", .{ interrupt_line, VEC_NO, IS_MASKED });
    //         int.triggerInterrupt(0x2a);
    //     },
    //     true => log.err("NVMe interrupt line: {x}, vector number: 0x{x}, is masked: {}", .{ interrupt_line, VEC_NO, IS_MASKED }),
    //- }

    // Delete existing I/O Submission Queue
    // log.debug("Delete existing I/O Submission Queues", .{});
    // for (1..(current_nsqr + 1)) |qid| {
    //     _ = executeAdminCommand(bar, &drive, @bitCast(IOQueueCommand{
    //         .deleteQ = .{
    //             .cdw0 = .{
    //                 .opc = .delete_io_sq,
    //                 .cid = @intCast(0x100 + qid), //our id
    //             },
    //             .qid = @intCast(qid),
    //         },
    //     })) catch |err| {
    //         log.err("Failed to execute Delete SQ Command for SQ qid={d}: {}", .{ qid, err });
    //         return;
    //     };
    // }
    //
    // // Delete existing I/O Completion Queue
    // log.debug("Delete existing I/O Completion Queues", .{});
    // for (1..(current_ncqr + 1)) |qid| {
    //     const delete_iocq_res = executeAdminCommand(bar, &drive, @bitCast(IOQueueCommand{
    //         .deleteQ = .{
    //             .cdw0 = .{
    //                 .opc = .delete_io_cq,
    //                 .cid = @intCast(0x200 + qid), //our id
    //             },
    //             .qid = @intCast(qid),
    //         },
    //     })) catch |err| {
    //         log.err("Failed to execute Delete CQ Command for CQ qid={d}: {}", .{ qid, err });
    //         return;
    //     };
    //
    //     // (sc==0 and sct=1) means no success (see. 5.5.1 in the NVME 2.0 spec)
    //     if (delete_iocq_res.status.sct != 0) {
    //         log.err("Delete I/O CQ failed qid:{0d}", .{qid});
    //         return;
    //     }
    // }

    //----{

    // const ss = executeAdminCommand(bar, &drive, @bitCast(SetFeatures0x07Command{
    //     .cdw0 = .{
    //         .opc = .set_features,
    //         .cid = 100, //our id
    //     },
    //     .fid = 0x07, //I/O Command Set Profile
    //     .ncqr = 1,
    //     .nsqr = 1,
    // })) catch |err| {
    //     log.err("Failed to execute Set Features Command(fid: 0x07): {}", .{err});
    //     return;
    // };
    //
    // const ncqalloc: u16 = @truncate(ss.cmd_res0 >> 16);
    // const nsqalloc: u16 = @truncate(ss.cmd_res0);
    // log.debug("ncqalloc/nsqalloc: {d}/{d}; status:{}", .{ ncqalloc, nsqalloc, ss.status });
    //
    // @memset(prp1, 0);
    // const get_features_0x07_current2_res = executeAdminCommand(bar, &drive, @bitCast(GetFeaturesCommand{
    //     .cdw0 = .{
    //         .opc = .get_features,
    //         .cid = 101, //our id
    //     },
    //     .dptr = .{
    //         .prp = .{
    //             .prp1 = prp1_phys,
    //         },
    //     },
    //     .fid = 0x07, //I/O Command Set Profile
    //     .sel = .current,
    // })) catch |err| {
    //     log.err("Failed to execute Get Features Command(fid: 0x07): {}", .{err});
    //     return;
    // };
    //
    // const current2_ncqr: u16 = @truncate(get_features_0x07_current2_res.cmd_res0 >> 16);
    // const current2_nsqr: u16 = @truncate(get_features_0x07_current2_res.cmd_res0);
    // log.debug("Get Features Command(fid: 0x07): !Current Number Of Completion/Submission Queues: {d}/{d} res0:0b{b:0>32}", .{ current2_ncqr, current2_nsqr, get_features_0x07_current_res.cmd_res0 });
    //
    //----}

    // Get Interrupt Coalescing
    // const get_interrupt_coalescing_res = executeAdminCommand(&drive, @bitCast(GetSetFeaturesCommand{
    //     .GetInterruptCoalescing = .{
    //         .cdw0 = .{
    //             .opc = .get_features,
    //             .cid = 0x0a, //our id
    //         },
    //         .sel = .current,
    //     },
    // })) catch |err| {
    //     log.err("Failed to execute Get Features Command(fid: 0x0a): {}", .{err});
    //     return;
    // };
    // const current_aggeration_time: u16 = @truncate((get_interrupt_coalescing_res.cmd_res0 >> 16) + 1); //0-based value, so 0 means 1
    // const current_aggregation_threshold: u16 = @truncate(get_interrupt_coalescing_res.cmd_res0 + 1); //0-based value
    //
    // log.debug("Get Interrupt Coalescing: Current Aggregation Time/Threshold: {d}/{d}", .{ current_aggeration_time, current_aggregation_threshold });
    //

    // Set Interrupt Coalescing
    _ = executeAdminCommand(dev, @bitCast(GetSetFeaturesCommand{
        .SetInterruptCoalescing = .{
            .cdw0 = .{
                .opc = .set_features,
                .cid = 0x0a, //our id
            },
            .thr = 0, //0-based value
            .time = 0, //0-based
        },
    })) catch |err| {
        log.err("Failed to execute Set Interrupt Coalescing: {}. Back to the defaults.", .{err});
    };

    // Get Interrupt Coalescing
    const get_interrupt_coalescing_res = executeAdminCommand(dev, @bitCast(GetSetFeaturesCommand{
        .get_interrupt_coalescing = .{
            .cdw0 = .{
                .opc = .get_features,
                .cid = 0x0b, //our id
            },
            .sel = .current,
        },
    })) catch |err| {
        log.err("Failed to execute Get Features Command(fid: 0x0b): {}", .{err});
        return;
    };
    const current_aggeration_time: u16 = @truncate((get_interrupt_coalescing_res.cmd_res0 >> 16) + 1); //0-based value, so 0 means 1
    const current_aggregation_threshold: u16 = @truncate(get_interrupt_coalescing_res.cmd_res0 + 1); //0-based value

    log.debug("Get Interrupt Coalescing: Current Aggregation Time/Threshold: {d}/{d}", .{ current_aggeration_time, current_aggregation_threshold });

    log.info("Create I/O Completion Queues", .{});
    // for (&dev.cq, 1..) |*cq, cq_id| {
    for (1..dev.cq.len) |cq_id| {
        var cq = &dev.cq[cq_id];
        cq.* = .{};

        cq.entries = heap.page_allocator.alloc(q.CQEntry, nvme_iocqs) catch |err| {
            log.err("Failed to allocate memory for completion queue entries: {}", .{err});
            return;
        };

        const cq_phys = paging.physFromPtr(dev.cq[cq_id].entries.ptr) catch |err| {
            log.err("Failed to get physical address of I/O Completion Queue: {}", .{err});
            return;
        };
        @memset(cq.entries, .{});

        const create_iocq_res = executeAdminCommand(dev, @bitCast(IoQueueCommand{
            .create_completion_queue = .{
                .cdw0 = .{
                    .opc = .create_io_cq,
                    .cid = @intCast(0x300 + cq_id), //our id
                },
                .dptr = .{
                    .prp = .{
                        .prp1 = cq_phys,
                    },
                },
                .qid = @intCast(cq_id), // we use only one queue
                .qsize = nvme_iocqs,
                .pc = true, // physically contiguous - the buddy allocator allocs memory in physically contiguous blocks
                .ien = true, // interrupt enabled
                .iv = tmp_msix_table_idx, //TODO: msi_x - message table entry index
            },
        })) catch |err| {
            log.err("Failed to execute Create CQ Command: {}", .{err});
            return;
        };

        cq.head_dbl = @ptrFromInt(doorbell_base + doorbell_size * (2 * cq_id + 1));

        _ = create_iocq_res; //TODO
    }

    log.info("Create I/O Submission Queues", .{});
    //for (&dev.sq[1..], 1..) |*sq, sq_id| {
    for (1..dev.sq.len) |sq_id| {
        var sq = &dev.sq[sq_id];
        sq.* = .{};

        sq.entries = heap.page_allocator.alloc(q.SQEntry, nvme_iosqs) catch |err| {
            log.err("Failed to allocate memory for submission queue entries: {}", .{err});
            return;
        };

        const sq_phys = paging.physFromPtr(dev.sq[sq_id].entries.ptr) catch |err| {
            log.err("Failed to get physical address of I/O Submission Queue: {}", .{err});
            return;
        };
        @memset(sq.entries, 0);

        const create_iosq_res = executeAdminCommand(dev, @bitCast(IoQueueCommand{
            .create_submission_queue = .{
                .cdw0 = .{
                    .opc = .create_io_sq,
                    .cid = @intCast(0x300 + sq_id), //our id
                },
                .dptr = .{
                    .prp = .{
                        .prp1 = sq_phys,
                    },
                },
                .qid = @intCast(sq_id), // we use only one queue
                .qsize = nvme_iosqs,
                .pc = true,
                .qprio = .medium,
                .cqid = @intCast(sq_id), // we use only one pair of queues
                .nvmsetid = 0, //TODO ?
            },
        })) catch |err| {
            log.err("Failed to execute Create SQ Command: {}", .{err});
            return;
        };

        // (sc==0 and sct=1) means no success (see. 5.5.1 in the NVME 2.0 spec)
        if (create_iosq_res.status.sct != 0) {
            log.err("Create I/O SQ failed qid:{0d} invalid cqid:{0d}", .{sq_id});
            return;
        }

        sq.tail_dbl = @ptrFromInt(doorbell_base + doorbell_size * (2 * sq_id));

        log.info("I/O Submission Queue created: qid:{d}, tail_dbl:0x{x}", .{ sq_id, sq.tail_dbl });
    }

    log.info("Configuration is done", .{});
}

pub fn init(allocator: std.mem.Allocator) !*NvmeDriver {
    log.info("Initializing NVMe driver", .{});
    var drv = try allocator.create(NvmeDriver);
    drv.alloctr = allocator;

    return drv;
}

pub fn driver(self: *NvmeDriver) Driver {
    const vtable = Driver.VTable{
        .probe = probe,
        .setup = setup,
        .deinit = deinit,
    };
    return Driver.init(self, vtable);
}

pub fn deinit(_: *anyopaque) void {
    log.info("Deinitializing NVMe driver", .{});
    // TODO: for now we don't have a way to unregister the driver

    // TODO: admin queue has been freed already - waiting for an error?
    // for (&dev.iocq) |*cq| heap.page_allocator.free(cq.entries);
    // for (&dev.iosq) |*sq| heap.page_allocator.free(sq.entries);
}

/// Execute an admin command
/// @param CDw0Type: Command Dword 0 type
/// @param drv: Device
/// @param cmd: SQEntry
/// @param sq_no: Submission Queue number
/// @param cq_no: Completion Queue number
fn execAdminCommand(CDw0Type: type, dev: *NvmeDevice, cmd: q.SQEntry, sqn: u16, cqn: u16) NvmeError!q.CQEntry {
    const cdw0: *const CDw0Type = @ptrCast(@alignCast(&cmd));
    log.debug("Executing command: CDw0: {}", .{cdw0.*});

    dev.sq[sqn].entries[dev.sq[sqn].tail_pos] = cmd;

    dev.sq[sqn].tail_pos += 1;
    if (dev.sq[sqn].tail_pos >= dev.sq[sqn].entries.len) dev.sq[sqn].tail_pos = 0;

    const cq_entry_ptr = &dev.cq[cqn].entries[dev.cq[cqn].head_pos];

    // press the doorbell
    dev.sq[sqn].tail_dbl.* = dev.sq[sqn].tail_pos;

    log.debug("Phase mismatch: CQEntry: {}, expected phase: {}", .{ cq_entry_ptr.phase, dev.cq[cqn].expected_phase });
    while (cq_entry_ptr.phase != dev.cq[cqn].expected_phase) {
        //log phase mismatch
        //log.debug("Phase mismatch(loop): CQEntry: {}, expected phase: {}", .{ cq_entry_ptr.*, drv.cq[cqn].expected_phase });

        const csts = regs.readRegister(regs.CSTSRegister, dev.bar, .csts);
        if (csts.cfs == 1) {
            log.err("Command failed", .{});
            return NvmeError.InvalidCommand;
        }
        if (csts.shst != 0) {
            if (csts.st == 1) log.err("NVE Subsystem is in shutdown state", .{}) else log.err("Controller is in shutdown state", .{});

            log.err("Controller is in shutdown state", .{});
            return NvmeError.InvalidCommand;
        }
        if (csts.nssro == 1) {
            log.err("Controller is not ready", .{});
            return NvmeError.InvalidCommand;
        }
        if (csts.pp == 1) {
            log.err("Controller is in paused state", .{});
            return NvmeError.InvalidCommand;
        }
    }

    if (cdw0.cid != cq_entry_ptr.cmd_id) {
        log.err("Invalid CID in CQEntry: {} for CDw0: {}", .{ cq_entry_ptr.*, cdw0 });
        return NvmeError.InvalidCommandSequence;
    }

    // TODO: do we need to check if conntroller is ready to accept new commands?
    //--  drv.asqa.header_pos = cqa_entry_ptr.sq_header_pos; //the controller position retuned in CQEntry as sq_header_pos

    dev.cq[cqn].head_pos += 1;
    if (dev.cq[cqn].head_pos >= dev.cq[cqn].entries.len) {
        dev.cq[cqn].head_pos = 0;
        // every new cycle we need to toggle the phase
        dev.cq[cqn].expected_phase = ~dev.cq[cqn].expected_phase;
    }

    //press the doorbell
    dev.cq[cqn].head_dbl.* = dev.cq[cqn].head_pos;

    if (sqn != cq_entry_ptr.sq_id) {
        log.err("Invalid SQ ID in CQEntry: {} for CDw0: {}", .{ cq_entry_ptr.*, cdw0 });
        return NvmeError.InvalidCommandSequence;
    }

    if (cq_entry_ptr.status.sc != 0) {
        log.err("Command failed (sc != 0): CDw0: {}, CQEntry: {}", .{ cdw0, cq_entry_ptr.* });
        return NvmeError.AdminCommandFailed;
    }

    log.debug("Command executed successfully: CDw0: {}, CQEntry = {}", .{ cdw0, cq_entry_ptr.* });
    return cq_entry_ptr.*;
}

fn executeAdminCommand(dev: *NvmeDevice, cmd: q.SQEntry) NvmeError!q.CQEntry {
    return execAdminCommand(AdminCDw0, dev, cmd, 0, 0);
}

fn execIoCommand(CDw0Type: type, drv: *NvmeDevice, cmd: q.SQEntry, sqn: u16, cqn: u16) NvmeError!q.CQEntry {
    const cdw0: *const CDw0Type = @ptrCast(@alignCast(&cmd));
    log.debug("Executing command: CDw0: {}", .{cdw0.*});

    drv.sq[sqn].entries[drv.sq[sqn].tail_pos] = cmd;

    log.debug("commented out /1", .{});

    drv.sq[sqn].tail_pos += 1;
    if (drv.sq[sqn].tail_pos >= drv.sq[sqn].entries.len) drv.sq[sqn].tail_pos = 0;

    log.debug("commented out /2", .{});

    const cq_entry_ptr = &drv.cq[cqn].entries[drv.cq[cqn].head_pos];

    // press the doorbell
    drv.sq[sqn].tail_dbl.* = drv.sq[sqn].tail_pos;
    log.debug("commented out /3", .{});

    log.debug("commented out /4", .{});

    log.debug("commented out /5", .{});

    // TODO: this silly loop must be removed
    while (!drv.mutex) {
        log.debug("Waiting for the controller to be ready", .{});
        const pending_bit = Pcie.readMsixPendingBitArrayBit(drv.msix_cap, drv.bar, tmp_msix_table_idx);
        log.debug("MSI-X pending bit: {}", .{pending_bit});
        apic_test.logRegistryState();
        cpu.halt();
    }
    drv.mutex = false;

    while (cq_entry_ptr.phase != drv.cq[cqn].expected_phase) {
        const csts = regs.readRegister(regs.CSTSRegister, drv.bar, .csts);
        if (csts.cfs == 1) {
            log.err("Command failed", .{});
            return NvmeError.InvalidCommand;
        }
        if (csts.shst != 0) {
            if (csts.st == 1) log.err("NVE Subsystem is in shutdown state", .{}) else log.err("Controller is in shutdown state", .{});

            log.err("Controller is in shutdown state", .{});
            return NvmeError.InvalidCommand;
        }
        if (csts.nssro == 1) {
            log.err("Controller is not ready", .{});
            return NvmeError.InvalidCommand;
        }
        if (csts.pp == 1) {
            log.err("Controller is in paused state", .{});
            return NvmeError.InvalidCommand;
        }
    }

    log.debug("commented out /5", .{});

    // TODO: do we need to check if conntroller is ready to accept new commands?
    //--  drv.asqa.header_pos = cqa_entry_ptr.sq_header_pos; //the controller position retuned in CQEntry as sq_header_pos
    drv.cq[cqn].head_pos += 1;
    if (drv.cq[cqn].head_pos >= drv.cq[cqn].entries.len) {
        drv.cq[cqn].head_pos = 0;
        // every new cycle we need to toggle the phase
        drv.cq[cqn].expected_phase = ~drv.cq[cqn].expected_phase;
    }

    //press the doorbell
    drv.cq[cqn].head_dbl.* = drv.cq[cqn].head_pos;

    if (sqn != cq_entry_ptr.sq_id) {
        log.err("Invalid SQ ID in CQEntry: {} for CDw0: {}", .{ cq_entry_ptr.*, cdw0 });
        return NvmeError.InvalidCommandSequence;
    }

    if (cq_entry_ptr.status.sc != 0) {
        log.err("Command failed: {}", .{cq_entry_ptr.*});
        return NvmeError.AdminCommandFailed;
    }

    log.debug("Command executed successfully: CDw0: {}, CQEntry = {}", .{ cdw0, cq_entry_ptr.* });
    return cq_entry_ptr.*;
    // return CQEntry{};
}

fn executeIoNvmCommand(drv: *NvmeDevice, cmd: q.SQEntry, sqn: u16, cqn: u16) NvmeError!q.CQEntry {
    return execIoCommand(IoNvmCDw0, drv, cmd, sqn, cqn);
}
//--- public functions ---

/// Read from the NVMe drive
/// @param allocator : Allocator
/// @param slba : Start Logical Block Address
/// @param nlb : Number of Logical Blocks
pub fn readToOwnedSlice(T: type, allocator: std.mem.Allocator, drv: *NvmeDevice, nsid: u32, slba: u64, nlba: u16) ![]T {
    const ns: NsInfo = drv.ns_info_map.get(nsid) orelse {
        log.err("Namespace {d} not found", .{nsid});
        return NvmeError.InvalidNsid;
    };

    log.debug("Namespace {d} info: {}", .{ nsid, ns });

    if (slba > ns.nsize) return NvmeError.InvalidLBA;

    const flbaf = ns.lbaf[ns.flbas];
    log.debug("LBA Format Index: {d}, LBA Format: {}", .{ ns.flbas, flbaf });

    const lbads_bytes = math.pow(u32, 2, flbaf.lbads);
    log.debug("LBA Data Size: {d} bytes", .{lbads_bytes});

    //calculate number of pages to allocate
    const total_bytes = nlba * lbads_bytes;
    const page_count = try std.math.divCeil(usize, total_bytes, pmm.page_size);
    log.debug("Number of pages to allocate: {d} to load: {d} bytes", .{ page_count, nlba * lbads_bytes });

    // calculate the physical address of the data buffer
    const data = allocator.alloc(T, total_bytes / @sizeOf(T)) catch |err| {
        log.err("Failed to allocate memory for data buffer: {}", .{err});
        return error.OutOfMemory;
    };
    @memset(data, 1); //TODO promote to an option

    const prp1_phys = paging.physFromPtr(data.ptr) catch |err| {
        log.err("Failed to get physical address: {}", .{err});
        return error.PageToPhysFailed;
    };

    var prp_list: ?[]usize = null;
    const prp2_phys: usize = switch (page_count) {
        0 => {
            log.err("No pages to allocate", .{});
            return error.PageFault;
        },
        1 => 0,
        2 => try paging.physFromPtr(data.ptr + pmm.page_size),
        else => blk: {
            const entry_size = @sizeOf(usize);
            const entry_count = page_count - 1;
            if (entry_count * entry_size > pmm.page_size) {
                //TODO: implement the logic to allocate more than one page for PRP list
                log.err("More than one PRP list not implemented", .{});
                return error.NotImplemented;
            }

            prp_list = allocator.alloc(usize, entry_count) catch |err| {
                log.err("Failed to allocate memory for PRP list: {}", .{err});
                return error.OutOfMemory;
            };

            for (0..entry_count) |i| {
                prp_list.?[i] = prp1_phys + pmm.page_size * (i + 1);
            }

            // log all entries in prp_list
            for (0..entry_count) |j| {
                log.debug("PRP list entry {d}: 0x{x}", .{ j, prp_list.?[j] });
            }

            break :blk try paging.physFromPtr(&prp_list.?[0]);
        },
    };
    defer if (prp_list) |pl| allocator.free(pl);
    log.debug("PRP1: 0x{x}, PRP2: 0x{x}", .{ prp1_phys, prp2_phys });

    // allotate memory for Metadata buffer
    const metadata = allocator.alloc(u8, nlba * flbaf.ms) catch |err| {
        log.err("Failed to allocate memory for metadata buffer: {}", .{err});
        return error.OutOfMemory;
    };
    defer allocator.free(metadata);
    @memset(metadata, 0);

    const mptr_phys = paging.physFromPtr(metadata.ptr) catch |err| {
        log.err("Failed to get physical address: {}", .{err});
        return error.PageToPhysFailed;
    };

    // choose sqn and cqn for the operation
    // TODO: implwement the logic to choose the right queue
    const sqn = 1;
    const cqn = 1;

    log.debug("Executing I/O NVM Command Set Read command", .{});
    _ = executeIoNvmCommand(drv, @bitCast(IoNvmCommandSetCommand{
        .read = .{
            .cdw0 = .{
                .opc = .read,
                .cid = 255, //our id
            },
            .nsid = nsid,
            .elbst_eilbst_a = 0, //no extended LBA
            .mptr = mptr_phys,
            .dptr = .{
                .prp = .{ .prp1 = prp1_phys, .prp2 = prp2_phys },
            },
            .slba = slba,
            .nlb = nlba - 1, //0's based value
            .stc = 0, //no streaming
            .prinfo = 0, //no protection info
            .fua = 0, //no force unit access
            .lr = 0, //no limited retry
            .dsm = .{
                .access_frequency = 0, //no dataset management
                .access_latency = 0, //no dataset management
                .sequential_request = 0, //no dataset management
                .incompressible = 0, //no dataset management
            }, //no dataset management
            .elbst_eilbst_b = 0, //no extended LBA
            .elbat = 0, //no extended LBA
            .elbatm = 0, //no extended LBA
        },
    }), sqn, cqn) catch |err| {
        log.err("Failed to execute IO NVM Command Set Read command: {}", .{err});
        return NvmeError.IONvmReadFailed;
    };

    //log metadata
    for (metadata) |m| log.debug("Metadata: 0x{x}", .{m});

    return data;
}

/// Write to the NVMe drive
/// @param allocator : Allocator to allocate memory for PRP list
/// @param drv : Device
/// @param nsid : Namespace ID
/// @param slba : Start Logical Block Address
/// @param data : Data to write
pub fn write(T: type, allocator: std.mem.Allocator, dev: *NvmeDevice, nsid: u32, slba: u64, data: []const T) !void {
    const ns: NsInfo = dev.ns_info_map.get(nsid) orelse {
        log.err("Namespace {d} not found", .{nsid});
        return NvmeError.InvalidNsid;
    };

    log.debug("Namespace {d} info: {}", .{ nsid, ns });

    if (slba > ns.nsize) return NvmeError.InvalidLBA;

    const flbaf = ns.lbaf[ns.flbas];
    log.debug("LBA Format Index: {d}, LBA Format: {}", .{ ns.flbas, flbaf });

    const lbads_bytes = math.pow(u32, 2, flbaf.lbads);
    log.debug("LBA Data Size: {d} bytes", .{lbads_bytes});

    // nlba = number of logical blocks to write
    const data_total_bytes = data.len * @sizeOf(T);
    const nlba: u16 = @intCast(try std.math.divCeil(usize, data_total_bytes, lbads_bytes));

    //calculate number of pages to allocate
    const total_bytes = nlba * lbads_bytes;
    const page_count = try std.math.divCeil(usize, total_bytes, pmm.page_size);
    log.debug("Number of pages to handle: {d} to load: {d} bytes", .{ page_count, nlba * lbads_bytes });

    const prp1_phys = paging.physFromPtr(data.ptr) catch |err| {
        log.err("Failed to get physical address: {}", .{err});
        return error.PageToPhysFailed;
    };

    var prp_list: ?[]usize = null;
    const prp2_phys: usize = switch (page_count) {
        0 => {
            log.err("No pages to allocate", .{});
            return error.PageFault;
        },
        1 => 0,
        2 => try paging.physFromPtr(data.ptr + pmm.page_size),
        else => blk: {
            const entry_size = @sizeOf(usize);
            const entry_count = page_count - 1;
            if (entry_count * entry_size > pmm.page_size) {
                //TODO: implement the logic to allocate more than one page for PRP list
                log.err("More than one PRP list not implemented", .{});
                return error.NotImplemented;
            }

            prp_list = allocator.alloc(usize, entry_count) catch |err| {
                log.err("Failed to allocate memory for PRP list: {}", .{err});
                return error.OutOfMemory;
            };

            for (0..entry_count) |i| {
                prp_list.?[i] = prp1_phys + pmm.page_size * (i + 1);
            }

            // log all entries in prp_list
            for (0..entry_count) |j| {
                log.debug("PRP list entry {d}: 0x{x}", .{ j, prp_list.?[j] });
            }

            break :blk try paging.physFromPtr(&prp_list.?[0]);
        },
    };
    defer if (prp_list) |pl| allocator.free(pl);
    log.debug("PRP1: 0x{x}, PRP2: 0x{x}", .{ prp1_phys, prp2_phys });

    // allotate memory for Metadata buffer
    const metadata = allocator.alloc(u8, nlba * flbaf.ms) catch |err| {
        log.err("Failed to allocate memory for metadata buffer: {}", .{err});
        return error.OutOfMemory;
    };
    defer allocator.free(metadata);
    @memset(metadata, 0);

    const mptr_phys = paging.physFromPtr(metadata.ptr) catch |err| {
        log.err("Failed to get physical address: {}", .{err});
        return error.PageToPhysFailed;
    };

    // choose sqn and cqn for the operation
    // TODO: implwement the logic to choose the right queue
    const sqn = 1;
    const cqn = 1;

    log.debug("Executing I/O NVM Command Set Read command", .{});
    _ = executeIoNvmCommand(dev, @bitCast(IoNvmCommandSetCommand{
        .write = .{
            .cdw0 = .{
                .opc = .write,
                .cid = 256, //our id
            },
            .nsid = nsid,
            .lbst_ilbst_a = 0, //no extended LBA
            .mptr = mptr_phys,
            .dptr = .{
                .prp = .{ .prp1 = prp1_phys, .prp2 = prp2_phys },
            },
            .slba = slba,
            .nlb = nlba - 1, //0's based value
            .dtype = 0, //no streaming TODO:???
            .stc = 0, //no streaming
            .prinfo = 0, //no protection info
            .fua = 0, //no force unit access
            .lr = 0, //no limited retry
            .dsm = .{
                .access_frequency = 0, //no dataset management
                .access_latency = 0, //no dataset management
                .sequential_request = 0, //no dataset management
                .incompressible = 0, //no dataset management
            }, //no dataset management
            .dspec = 0, //no dataset management
            .lbst_ilbst_b = 0, //no extended LBA
            .lbat = 0, //no extended LBA
            .lbatm = 0, //no extended LBA
        },
    }), sqn, cqn) catch |err| {
        log.err("Failed to execute IO NVM Command Set Read command: {}", .{err});
        return NvmeError.IONvmReadFailed;
    };

    //log metadata
    for (metadata) |m| log.debug("Metadata: 0x{x}", .{m});
}
