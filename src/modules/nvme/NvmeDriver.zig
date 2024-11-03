const std = @import("std");
const log = std.log.scoped(.nvme_driver);
const math = std.math;

//const apic_test = @import("../arch/x86_64/apic.zig");
const cpu = @import("deps.zig").cpu;
const int = @import("deps.zig").int;
const pmm = @import("deps.zig").pmm;
const paging = @import("deps.zig").paging;
const heap = @import("deps.zig").heap;

const Device = @import("deps.zig").Device;
const Driver = @import("deps.zig").Driver;
const BlockDevice = @import("deps.zig").BlockDevice;
const Pcie = @import("deps.zig").Pcie;

const NvmeController = @import("NvmeController.zig");
const msix = @import("msix.zig");
//const ctrl = @import("controller.zig");
const regs = @import("registers.zig");
const feat = @import("admin/features.zig");
const acmd = @import("admin/command.zig");
//const iocmd = @import("io/command.zig");
const aq = @import("admin/queue.zig");
//const io = @import("io/io.zig");
const e = @import("errors.zig");
const id = @import("admin/identify.zig");
pub const com = @import("commons.zig");
const NvmeNamespace = @import("NvmeNamespace.zig");

const nvme_class_code = 0x01;
const nvme_subclass = 0x08;
const nvme_prog_if = 0x02;

const nvme_iosqs = 0x8; //submisstion queue size(length)
const nvme_iocqs = 0x8; //completion queue size
const nvme_ioacqs = 0x2; //admin completion queue size
const nvme_ioasqs = 0x2; //admin submission queue size

//const nvme_ncqr = 0x1 + 0x1; //number of completion queues requested (+1 is admin cq)
//const nvme_nsqr = nvme_ncqr; //number of submission queues requested
//
//

//TODO: refactor this
const tmp_msix_table_idx = 0x01;
//@@@const tmp_irq = 0x33;

const NvmeDriver = @This();

//Fields
alloctr: std.mem.Allocator,

// TODO: When packed tagged unions are supported, we can use the following definitions
// const SQEntry = packed union(enum) {
//    identify: IdentifyCommand, //or body of the command
//    abort: AbortCommand,
//    //...
// };

//pub const NsInfoMap = std.AutoHashMap(u32, id.NsInfo);

/// Devicer interface function to match the driver with the device
pub fn probe(_: *anyopaque, probe_ctx: *const anyopaque) bool {
    const pcie_ctx: *const Pcie.PcieProbeContext = @ptrCast(@alignCast(probe_ctx));
    return pcie_ctx.class_code == nvme_class_code and pcie_ctx.subclass == nvme_subclass and pcie_ctx.prog_if == nvme_prog_if;
}

/// Devicer interface function
pub fn setup(ctx: *anyopaque, base: *Device) !void {
    const self: *NvmeDriver = @ptrCast(@alignCast(ctx));
    base.driver = self.driver();
    //base.spec = .{ .block = .{ .nvme = .{ .base = base } } };
    var block = try BlockDevice.init(base.alloctr, base);
    const ctrl = try NvmeController.init(base.alloctr, base);
    block.spec.nvme_ctrl = ctrl;
    base.spec.block = block;

    // now we can access the NVMe device
    const addr = base.addr.pcie;

    try validatePcieVersion(addr);
    try ctrl.disableMsi();
    try ctrl.enableMsix();

    // //- var pci_cmd_reg = Pcie.readRegisterWithArgs(u16, .command, function, slot, bus);
    //disable interrupts while using MSI-X
    //-pci_cmd_reg |= 1 << 15;
    //-Pcie.writeRegisterWithArgs(u16, .command, function, slot, bus, pci_cmd_reg);
    // const VEC_NO: u16 = 0x20 + interrupt_line; //TODO: we need MSI/MSI-X support first - PIC does not work here

    //@@@ctrl.ns_info_map = NsInfoMap.init(base.alloctr);
    ctrl.namespaces = NvmeController.NamespaceMap.init(base.alloctr);
    ctrl.bar = Pcie.readBarWithArgs(.bar0, addr);

    // Initialize queues to the default values
    for (&ctrl.sq) |*sq| {
        //Add code here if needed
        sq.* = .{};
    }
    for (&ctrl.cq) |*cq| {
        //Add code here if needed
        cq.* = .{};
    }

    //MSI-X
    // TODO: refactor me:
    //Get free interrupt vector
    const interrupt = int.acquireAnyInterrupt() catch |err| {
        log.err("Failed to acquire free interrupt: {}", .{err});
        return;
    };
    log.info("Acquired interrupt vector: 0x{0x}, dec:{0d}", .{interrupt});
    msix.configureMsix(ctrl, tmp_msix_table_idx, interrupt) catch |err| {
        log.err("Failed to configure MSI-X: {}", .{err});
    };

    //log pending bit in MSI-X
    const pending_bit = Pcie.readMsixPendingBitArrayBit(ctrl.msix_cap, ctrl.bar, 0x0);
    log.info("MSI-X pending bit: {}", .{pending_bit});

    //  bus-mastering DMA, and memory space access in the PCI configuration space
    const command = Pcie.readRegisterWithArgs(u16, .command, addr);
    log.warn("PCI command register: 0b{b:0>16}", .{command});
    // Enable interrupts, bus-mastering DMA, and memory space access in the PCI configuration space for the function.
    Pcie.writeRegisterWithArgs(u16, .command, addr, command | 0b110);

    const virt = switch (ctrl.bar.address) {
        inline else => |phys| paging.virtFromMME(phys),
    };

    // Adjust if needed page PAT to write-through
    const size: usize = switch (ctrl.bar.size) {
        .as32 => ctrl.bar.size.as32,
        .as64 => ctrl.bar.size.as64,
    };

    log.debug("Adjusting page area for NVMe BAR: {} size: {}", .{ virt, size });
    paging.adjustPageAreaPAT(virt, size, .write_through) catch |err| {
        log.err("Failed to adjust page area PAT for NVMe BAR: {}", .{err});
        return;
    };
    paging.debugLowestEntryFromVirt(virt); //to be commented out
    // End of adjustment

    // dumpRegisters(ctrl); //TODO: Uncomment this if needed

    try verifyController(ctrl);

    // Reset the controllerg
    ctrl.disableController();

    const doorbell_base: usize = virt + 0x1000;
    const cap = regs.readRegister(regs.CAPRegister, ctrl.bar, .cap);
    const doorbell_size = math.pow(u32, 2, 2 + cap.dstrd);

    try preConfigureController(ctrl, doorbell_base, doorbell_size);

    ctrl.enableController();

    // I/O Command Set specific initialization
    try discoverNamespacesByIoCommandSet(ctrl);

    // Create I/O queues
    try createIoQueues(ctrl, doorbell_base, doorbell_size);

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

//--- private functions
fn validatePcieVersion(addr: Pcie.PcieAddress) !void {
    const pcie_version = try Pcie.readCapability(Pcie.VersionCap, addr);
    log.info("PCIe version: {}", .{pcie_version});

    if (pcie_version.major < 2) {
        log.err("Unsupported PCIe version: {}.{}", .{ pcie_version.major, pcie_version.minor });
        return error.UnsupportedPcieVersion;
    }
}

/// verifyController checks if the controller is supported by the driver
fn verifyController(ctrl: *NvmeController) !void {
    // Check the controller version
    const vs = regs.readRegister(regs.VSRegister, ctrl.bar, .vs);
    log.info("NVMe controller version: {}.{}.{}", .{ vs.mjn, vs.mnr, vs.tet });

    // support only NVMe 1.4 and 2.0
    if (vs.mjn == 1 and vs.mnr < 4) {
        log.err("Unsupported NVMe controller major version:  {}.{}.{}", .{ vs.mjn, vs.mnr, vs.tet });
        return e.NvmeError.UnsupportedControllerVersion;
    }

    // Check if the controller supports NVM Command Set and Admin Command Set
    const cap = regs.readRegister(regs.CAPRegister, ctrl.bar, .cap);
    log.info("NVME CAP Register: {}", .{cap});
    if (cap.css.nvmcs == 0) {
        log.err("NVMe controller does not support NVM Command Set", .{});
        return e.NvmeError.ControllerDoesNotSupportNvmCommandSet;
    }

    if (cap.css.acs == 0) {
        log.err("NVMe controller does not support Admin Command Set", .{});
        return e.NvmeError.ControllerDoesNotSupportAdminCommandSet;
    }

    const cc = regs.readRegister(regs.CCRegister, ctrl.bar, .cc);
    log.info("NVMe controller supports min/max memory page size: 2^(12 + cap.mpdmin:{d}) -> 2^(12 + cap.mpdmssx: {d}), 2^(12 + cc.mps: {d})", .{ cap.mpsmin, cap.mpsmax, cc.mps });
    const sys_mps: u4 = @intCast(math.log2(pmm.page_size) - 12);
    if (cap.mpsmin < sys_mps or sys_mps > cap.mpsmax) {
        log.err("NVMe controller does not support the host's memory page size", .{});
        return e.NvmeError.ControllerDoesNotSupportHostPageSize;
    }
}

// preConfigureController sets up the controller before the controller is enabled
// ctrl: the controller to configure
fn preConfigureController(ctrl: *NvmeController, doorbell_base: usize, doorbell_size: u32) !void {
    // The host configures the Admin Queue by setting the Admin Queue Attributes (AQA), Admin Submission Queue Base Address (ASQ), and Admin Completion Queue Base Address (ACQ) the appropriate values;
    //set AQA queue sizes
    var aqa = regs.readRegister(regs.AQARegister, ctrl.bar, .aqa);
    log.info("NVMe AQA Register pre-modification: {}", .{aqa});
    aqa.asqs = nvme_ioasqs;
    aqa.acqs = nvme_ioacqs;
    regs.writeRegister(regs.AQARegister, ctrl.bar, .aqa, aqa);
    aqa = regs.readRegister(regs.AQARegister, ctrl.bar, .aqa);
    log.info("NVMe AQA Register post-modification: {}", .{aqa});

    // ASQ and ACQ setup
    ctrl.sq[0].entries = try heap.page_allocator.alloc(com.SQEntry, nvme_ioasqs);
    defer heap.page_allocator.free(@volatileCast(ctrl.sq[0].entries));
    @memset(ctrl.sq[0].entries, 0);

    ctrl.cq[0].entries = try heap.page_allocator.alloc(com.CQEntry, nvme_ioacqs);
    defer heap.page_allocator.free(@volatileCast(ctrl.cq[0].entries));
    @memset(ctrl.cq[0].entries, .{});

    const sqa_phys = try paging.physFromPtr(ctrl.sq[0].entries.ptr);
    const cqa_phys = try paging.physFromPtr(ctrl.cq[0].entries.ptr);

    log.debug("ASQ: virt: {*}, phys:0x{x}; ACQ: virt:{*}, phys:0x{x}", .{ ctrl.sq[0].entries, sqa_phys, ctrl.cq[0].entries, cqa_phys });

    var asq = regs.readRegister(regs.ASQEntry, ctrl.bar, .asq);
    log.info("ASQ Register pre-modification: 0x{x}", .{@shlExact(asq.asqb, 12)});
    asq.asqb = @intCast(@shrExact(sqa_phys, 12)); // 4kB aligned
    regs.writeRegister(regs.ASQEntry, ctrl.bar, .asq, asq);
    asq = regs.readRegister(regs.ASQEntry, ctrl.bar, .asq);
    log.info("ASQ Register post-modification: 0x{x}", .{@shlExact(asq.asqb, 12)});

    var acq = regs.readRegister(regs.ACQEntry, ctrl.bar, .acq);
    log.info("ACQ Register pre-modification: 0x{x}", .{@shlExact(acq.acqb, 12)});
    acq.acqb = @intCast(@shrExact(cqa_phys, 12)); // 4kB aligned
    regs.writeRegister(regs.ACQEntry, ctrl.bar, .acq, acq);
    acq = regs.readRegister(regs.ACQEntry, ctrl.bar, .acq);
    log.info("ACQ Register post-modification: 0x{x}", .{@shlExact(acq.acqb, 12)});

    const cap = regs.readRegister(regs.CAPRegister, ctrl.bar, .cap);
    var cc = regs.readRegister(regs.CCRegister, ctrl.bar, .cc);
    log.info("CC register pre-modification: {}", .{cc});
    //CC.css settings
    if (cap.css.acs == 1) cc.css = 0b111;
    if (cap.css.iocs == 1) cc.css = 0b110 else if (cap.css.nvmcs == 0) cc.css = 0b000;
    // Set page size as the host's memory page size
    cc.mps = @intCast(math.log2(pmm.page_size) - 12);
    // Set the arbitration mechanism to round-robin
    cc.ams = .round_robin;
    cc.iosqes = 6; // 64 bytes - set to recommened value
    cc.iocqes = 4; // 16 bytes - set to
    regs.writeRegister(regs.CCRegister, ctrl.bar, .cc, cc);
    log.info("CC register post-modification: {}", .{regs.readRegister(regs.CCRegister, ctrl.bar, .cc)});

    ctrl.sq[0].tail_dbl = @ptrFromInt(doorbell_base + doorbell_size * 0);
    ctrl.cq[0].head_dbl = @ptrFromInt(doorbell_base + doorbell_size * 1);
}

fn discoverNamespacesByIoCommandSet(ctrl: *NvmeController) !void {
    const prp1 = try heap.page_allocator.alloc(u8, pmm.page_size);
    @memset(prp1, 0);
    defer heap.page_allocator.free(prp1);

    const prp1_phys = try paging.physFromPtr(prp1.ptr);

    // Identify Command CNS=0x00 crosses the PRP1 memory boundary and Tripple Fault accours then, TODO: Explanation needed
    //const prp2 = try heap.page_allocator.alloc(u8, pmm.page_size);
    // @memset(prp2, 0);
    // defer heap.page_allocator.free(prp2);
    // const prp2_phys = try paging.physFromPtr(prp2.ptr);

    _ = acmd.executeAdminCommand(ctrl, @bitCast(id.IdentifyCommand{
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
        return e.NvmeError.FailedToExecuteIdentifyCommand;
    };

    const io_command_set_combination_lst: *const [512]id.IoCommandSet = @ptrCast(@alignCast(prp1));
    //TODO: find only one command set vector combination (comman set with specific ), that's not true cause there could be more than one
    var cmd_set_cmb: id.IoCommandSet = undefined; //we choose the first combination
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
            return e.NvmeError.NoValidIoCommandSetCombination;
        }
    };

    // Set I/O Command Set Profile with Command Set Combination index
    @memset(prp1, 0);
    _ = acmd.executeAdminCommand(ctrl, @bitCast(feat.GetSetFeaturesCommand{
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
        return e.NvmeError.FailedToExecuteSetFeaturesCommand;
    };

    // I/O Command Set specific Active Namespace ID list (CNS 07h)
    // Each Command Set may have a list of active Namespace IDs
    for ([_]u1{ cmd_set_cmb.nvmcs, cmd_set_cmb.kvcs, cmd_set_cmb.zncs }, 0..) |csi, i| {
        if (csi == 0) continue;
        log.info("I/O Command Set specific Active Namespace ID list(0x07): command set idx:{d} -> csi:{d}", .{ i, csi });
        @memset(prp1, 0);
        _ = acmd.executeAdminCommand(ctrl, @bitCast(id.IdentifyCommand{
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
            return e.NvmeError.FailedToExecuteIdentifyCommand;
        };

        const io_command_set_active_nsid_lst: *const [1024]com.NsId = @ptrCast(@alignCast(prp1));
        for (io_command_set_active_nsid_lst, 0..) |nsid, j| {
            //stop on first non-zero nsid
            //log.info("Identify I/O Command Set Active Namespace ID List(0x07): command set idx:{d} nsid idx:{d}, nsid:{d}", .{ i, j, nsid });
            if (nsid != 0) {
                log.info("Identify I/O Command Set Active Namespace ID List(0x07): command set idx:{d} nsid idx:{d}, nsid:{d}", .{ i, j, nsid });

                // Identify Namespace Data Structure (CNS 0x00)
                @memset(prp1, 0);
                //@memset(prp2, 0);
                _ = acmd.executeAdminCommand(ctrl, @bitCast(id.IdentifyCommand{
                    .cdw0 = .{
                        .opc = .identify,
                        .cid = 0x05, //our id
                    },
                    .nsid = nsid,
                    .dptr = .{
                        .prp = .{
                            .prp1 = prp1_phys,
                            //           .prp2 = prp2_phys, //TODO: it's not documented but this command crosses the prp1 memory boundary
                        },
                    },
                    .cns = 0x00,
                })) catch |err| {
                    log.warn("Identify Command(cns:0x00) failed with error: {}", .{err});
                    continue; // we do not return as we want to continue with other namespaces
                };

                const ns_info: *const id.IdentifyNamespaceInfo = @ptrCast(@alignCast(prp1));
                log.info("Identify Namespace Data Structure(cns: 0x00): nsid:{d}, info:{}", .{ nsid, ns_info.* });

                try ctrl.namespaces.put(nsid, try NvmeNamespace.init(heap.page_allocator, ctrl, nsid, ns_info.*));

                const vs = regs.readRegister(regs.VSRegister, ctrl.bar, .vs); //TODO added to compile the code
                log.debug("vs: {}", .{vs});
                if (vs.mjn == 2) {
                    // TODO: see section 8.b in the 3.5.1 Memory-based Transport Controller Initialization chapter
                    // TODO: implement it when qemu is ready to handle with NVMe v2.0

                    log.debug("vs2: {}", .{vs});
                    // CNS 05h: I/O Command Set specific Identify Namespace data structure
                    @memset(prp1, 0);
                    _ = acmd.executeAdminCommand(ctrl, @bitCast(id.IdentifyCommand{
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
                        return e.NvmeError.FailedToExecuteIdentifyCommand;
                    };

                    const ns_io_info: *const id.IoCommandSetNamespaceInfo = @ptrCast(@alignCast(prp1));
                    log.info("Identify I/O Command Set specific Identify Namespace data structure for the specified NSID (cns: 0x05): nsid:{d}, info:{}", .{ nsid, ns_io_info.* });

                    // CNS 06h: I/O Command Set specific Identify Controller data structure
                    @memset(prp1, 0);
                    _ = acmd.executeAdminCommand(ctrl, @bitCast(id.IdentifyCommand{
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
                        return e.NvmeError.FailedToExecuteIdentifyCommand;
                    };

                    const ns_ctrl_info: *const id.IoCommandSetControllerInfo = @ptrCast(@alignCast(prp1));
                    log.info("Identify I/O Command Set specific Identify Controller data structure for the specified NSID (cns: 0x06): nsid:{d}, info:{}", .{ nsid, ns_ctrl_info.* });

                    // CNS 08h: I/O Command Set independent Identify Namespace data structure
                    @memset(prp1, 0);
                    _ = acmd.executeAdminCommand(ctrl, @bitCast(id.IdentifyCommand{
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
                        return e.NvmeError.FailedToExecuteIdentifyCommand;
                    };

                    const ns_indep_info: *const id.IoCommandSetIndependentNamespaceInfo = @ptrCast(@alignCast(prp1));
                    log.info("Identify I/O Command Set Independent Identify Namespace data structure for the specified NSID (cns: 0x08): nsid:{d}, info:{}", .{ nsid, ns_indep_info.* });
                } //vs.mjr==2
            }
        } // nsids
    }
}

fn createIoQueues(ctrl: *NvmeController, doorbell_base: usize, doorbell_size: u32) !void {
    //we use page allocator cause we need to be aligned to the page size
    const pg_alloctr = heap.page_allocator;
    // Get current I/O number of completion/submission queues
    const get_current_number_of_queues_res = acmd.executeAdminCommand(ctrl, @bitCast(feat.GetSetFeaturesCommand{
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
    const get_default_number_of_queues_res = acmd.executeAdminCommand(ctrl, @bitCast(feat.GetSetFeaturesCommand{
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

    if (ctrl.ncqr > supported_ncqr or ctrl.nsqr > supported_nsqr) {
        log.err("Requested number of completion/submission queues is not supported", .{});
    }

    // Set Interrupt Coalescing
    _ = acmd.executeAdminCommand(ctrl, @bitCast(feat.GetSetFeaturesCommand{
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
    const get_interrupt_coalescing_res = acmd.executeAdminCommand(ctrl, @bitCast(feat.GetSetFeaturesCommand{
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
    for (1..ctrl.cq.len) |cq_id| {
        var cq = &ctrl.cq[cq_id];
        cq.* = .{};

        cq.entries = try pg_alloctr.alloc(com.CQEntry, nvme_iocqs);
        const cq_phys = try paging.physFromPtr(ctrl.cq[cq_id].entries.ptr);
        @memset(cq.entries, .{});

        const create_iocq_res = acmd.executeAdminCommand(ctrl, @bitCast(aq.IoQueueCommand{
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
            return e.NvmeError.FailedToExecuteCreateCQCommand;
        };

        cq.head_dbl = @ptrFromInt(doorbell_base + doorbell_size * (2 * cq_id + 1));

        _ = create_iocq_res; //TODO
    }

    log.info("Create I/O Submission Queues", .{});
    //for (&dev.sq[1..], 1..) |*sq, sq_id| {
    for (1..ctrl.sq.len) |sq_id| {
        var sq = &ctrl.sq[sq_id];
        sq.* = .{};

        sq.entries = try heap.page_allocator.alloc(com.SQEntry, nvme_iosqs);
        const sq_phys = try paging.physFromPtr(ctrl.sq[sq_id].entries.ptr);
        @memset(sq.entries, 0);

        const create_iosq_res = acmd.executeAdminCommand(ctrl, @bitCast(aq.IoQueueCommand{
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
            return e.NvmeError.FailedToExecuteCreateSQCommand;
        };

        // (sc==0 and sct=1) means no success (see. 5.5.1 in the NVME 2.0 spec)
        if (create_iosq_res.status.sct != 0) {
            log.err("Create I/O SQ failed qid:{0d} invalid cqid:{0d}", .{sq_id});
            return e.NvmeError.FailedToCreateIOSQ;
        }

        sq.tail_dbl = @ptrFromInt(doorbell_base + doorbell_size * (2 * sq_id));

        log.info("I/O Submission Queue created: qid:{d}, tail_dbl:0x{x}", .{ sq_id, sq.tail_dbl });
    }
}

fn identifyController(ctrl: *NvmeController) !void {
    // Allocate one prp1 for all commands
    const prp1 = try heap.page_allocator.alloc(u8, pmm.page_size);
    @memset(prp1, 0);
    defer heap.page_allocator.free(prp1);
    const prp1_phys = try paging.physFromPtr(prp1.ptr);

    _ = acmd.executeAdminCommand(ctrl, @bitCast(id.IdentifyCommand{
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
        return e.NvmeError.FailedToExecuteIdentifyCommand;
    };

    const identify_info: *const id.ControllerInfo = @ptrCast(@alignCast(prp1));
    log.info("Identify Controller Data Structure(cns: 0x01): {}", .{identify_info.*});

    const ctrl_type: NvmeController.ControllerType = @enumFromInt(identify_info.cntrl);
    if (ctrl_type != NvmeController.ControllerType.io_controller) {
        log.err("Unsupported NVMe controller type: {}", .{identify_info.cntrltype});
        return e.NvmeError.UnsupportedControllerType;
    }
    ctrl.type = ctrl_type;

    const cc = regs.readRegister(regs.CCRegister, ctrl.bar, .cc);
    ctrl.mdts_bytes = math.pow(u32, 2, 12 + cc.mps + identify_info.mdts);
    log.info("MDTS in kbytes: {}", .{ctrl.mdts_bytes / 1024});
}

/// logRegisters logs the content of the NVMe register set directly using the pointer to the register set
fn dumpRegisters(ctrl: *const NvmeController) void {
    const virt = switch (ctrl.bar.address) {
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

    //log register_set_ptr content
    log.debug("NVMe register set at address {}:", .{register_set_ptr.*});

    log.debug(
        \\bar:{}, addr:0x{x},
        \\cap: 0b{b:0>64}, vs: 0b{b:0>32}
        \\intms: 0b{b:0>32}, intmc: 0b{b:0>32}
        \\cc: 0b{b:0>32}, csts: 0b{b:0>32}
        \\aqa: 0b{b:0>32}, asq: 0b{b:0>64}, acq: 0b{b:0>64}
    , .{
        ctrl.bar,
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
}
