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

const nvme_iosqs = 0x2; //submisstion queue length
const nvme_iocqs = 0x2; //completion queue length
const nvme_ioasqs = 0x2; //admin submission queue length
const nvme_ioacqs = 0x2; //admin completion queue length

const Self = @This();

const NVMeError = error{
    InvalidCommand,
};

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
        prp2: u64,
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
    ignrd_a: u32 = 0, //04:07 byte - nsid
    ignrd_b: u32 = 0, //08:11 byte - cdw2
    ignrd_c: u32 = 0, //12:15 byte = cdw3
    ignrd_e: u64 = 0, //16:23 byte = mptr
    dptr: DataPointer, //24:39 byte = prp1, prp2
    cns: u8, //00:07 id cdw10
    rsrv_a: u8 = 0, //08:15 in cdw10
    cntid: u16, //16-31 in cdw10
    ignrd_f: u32 = 0, //44:47 in cdw11
    ignrd_g: u32 = 0, //48-52 in cdw12
    ignrd_h: u32 = 0, //52-55 in cdw13
    uuid: u7, //00-06 in cdw14
    rsrvd_b: u25 = 0, //07-31 in cdw14
    ignrd_j: u32 = 0, //60-63 in cdw15
};

const IdentifyInfo = extern struct {
    vid: u16, // 2bytes
    ssvid: u16, //2bytes
    sn: [20]u8, //20bytes
    mn: [40]u8, //40bytes
    fr: [8]u8, //8bytes
    rab: u8, //1byte
    ieee: [3]u8, //3bytes
    cmic: u8, //1byte
    mdts: u8, //1byte
    cntlid: u16, //2bytes
    ver: u32, //4bytes
    //fill gap to 111 bytes
    ignrd_a: [111 - 84]u8,
    cntrltype: u8, //111 bajt
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
    sq_header_ptr: u16 = 0,
    sq_id: u16 = 0,
    cmd_id: u16 = 0,
    phase: u1 = 0,
    status: CQEStatusField = .{},
};

const Drive = struct {
    sqa: []volatile SQEntry = undefined,
    cqa: []volatile CQEntry = undefined,

    sqa_tail_pos: u32 = 0, // private counter to keep track and update sqa_tail_dbl
    sqa_tail_dbl: *volatile u32 = undefined, //each doorbell value is u32, minmal doorbell stride is 4 (2^(2+CAP.DSTRD))
    cqa_head_pos: u32 = 0,
    cqa_head_dbl: *volatile u32 = undefined, //each doorbell value is u32, minmal doorbell stride is 4 (2^(2+CAP.DSTRD))

    sq_tail_pos: u32 = 0, //private counter to keep track and update sq_tail_dbl
    sq_tail_dbl: *volatile u32 = undefined,
    cq_head_dbl: *volatile u32 = undefined,

    expected_phase: u1 = 1, //private counter to keep track of the expected phase

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

    const sqa_phys = paging.recPhysFromVirt(@intFromPtr(drive.sqa.ptr)) catch |err| {
        log.err("Failed to get physical address of admin submission queue: {}", .{err});
        return;
    };
    const cqa_phys = paging.recPhysFromVirt(@intFromPtr(drive.cqa.ptr)) catch |err| {
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
    // Set page size as the host's memory page size
    cc.mps = sys_mps;
    // Set the arbitration mechanism to round-robin
    cc.ams = .round_robin;
    writeRegister(CCRegister, bar, .cc, cc);
    log.info("CC register post-modification: {}", .{readRegister(CCRegister, bar, .cc)});

    enableController(bar);

    const doorbell_base: usize = virt + 0x1000;
    const doorbell_size = math.pow(u32, 2, 2 + cap.dstrd);
    drive.sqa_tail_dbl = @ptrFromInt(doorbell_base + doorbell_size * 0);
    drive.cqa_head_dbl = @ptrFromInt(doorbell_base + doorbell_size * 1);
    drive.sq_tail_dbl = @ptrFromInt(doorbell_base + doorbell_size * 2);
    drive.cq_head_dbl = @ptrFromInt(doorbell_base + doorbell_size * 3);

    log.info("NVMe interrupt line: {}", .{interrupt_line});
    const unique_id = pci.uniqueId(bus, slot, function);
    int.addISR(interrupt_line, .{ .unique_id = unique_id, .func = handleInterrupt }) catch |err| {
        log.err("Failed to add NVMe interrupt handler: {}", .{err});
    };

    const identify_prp1 = heap.page_allocator.alloc(u8, pmm.page_size) catch |err| {
        log.err("Failed to allocate memory for identify command: {}", .{err});
        return;
    };
    @memset(identify_prp1, 0);
    defer heap.page_allocator.free(identify_prp1);
    const identify_prp1_phys = paging.recPhysFromVirt(@intFromPtr(identify_prp1.ptr)) catch |err| {
        log.err("Failed to get physical address of identify command: {}", .{err});
        return;
    };
    const identify_cmd = IdentifyCommand{
        .cdw0 = .{
            .opc = .identify,
            .cid = 0x01, //our id
        },
        .dptr = .{
            .prp = .{
                .prp1 = identify_prp1_phys,
                .prp2 = 0, //we need only one page
            },
        },
        .cns = 0x01,
        .cntid = 0, //0 cause we do not use it
        .uuid = 0, //0 cause we do not use it
    };
    const res_status = executeAdminCommand(bar, &drive, @bitCast(identify_cmd)) catch |err| {
        log.err("Failed to execute identify command: {}", .{err});
        return;
    };

    if (res_status.sc != 0) {
        log.err("Identify command failed with status: {}", .{res_status});
        return;
    }

    const identify_info: *const IdentifyInfo = @ptrCast(@alignCast(identify_prp1));
    log.info("Identify info: {}", .{identify_info.*});
    if (identify_info.cntrltype != @intFromEnum(ControllerType.io_controller)) {
        log.err("Unsupported NVMe controller type: {}", .{identify_info.cntrltype});
        return;
    }

    // log.warn("RegisterSet.cap offset: 0x{x}", .{@offsetOf(RegisterSet, "cap")});
    // log.warn("RegisterSet.vs offset: 0x{x}", .{@offsetOf(RegisterSet, "vs")});
    // log.warn("RegisterSet.intms offset: 0x{x}", .{@offsetOf(RegisterSet, "intms")});
    // log.warn("RegisterSet.intmc offset: 0x{x}", .{@offsetOf(RegisterSet, "intmc")});
    // log.warn("RegisterSet.cc offset: 0x{x}", .{@offsetOf(RegisterSet, "cc")});
    // log.warn("RegisterSet.csts offset: 0x{x}", .{@offsetOf(RegisterSet, "csts")});
    // log.warn("RegisterSet.aqa offset: 0x{x}", .{@offsetOf(RegisterSet, "aqa")});
    // log.warn("RegisterSet.asq offset: 0x{x}", .{@offsetOf(RegisterSet, "asq")});
    // log.warn("RegisterSet.acq offset: 0x{x}", .{@offsetOf(RegisterSet, "acq")});
    //
    // TODO: remove this
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

fn executeAdminCommand(bar: pci.BAR, drv: *Drive, cmd: SQEntry) NVMeError!CQEStatusField {
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
    }

    drv.cqa_head_pos += 1;
    if (drv.cqa_head_pos >= drv.cqa.len) {
        drv.cqa_head_pos = 0;
        // every new cycle we need to toggle the phase
        drv.expected_phase = ~drv.expected_phase;
    }

    //press the doorbell
    drv.cq_head_dbl.* = drv.cqa_head_pos;

    log.info("Admin command executed successfully: CQEntry = {}", .{cqa_entry_ptr.*});
    return cqa_entry_ptr.status;
}
