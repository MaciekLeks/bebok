const std = @import("std");
const math = std.math;

const pmm = @import("deps.zig").pmm;
const paging = @import("deps.zig").paging;
const heap = @import("deps.zig").heap;
const Pcie = @import("deps.zig").Pcie;
const NvmeDriver = @import("deps.zig").NvmeDriver;

const io = @import("deps.zig").nvme_io;
const id = @import("deps.zig").nvme_id;
const e = @import("deps.zig").nvme_e;
const iocmd = @import("deps.zig").nvme_iocmd;
const regs = @import("deps.zig").regs;

const BlockDevice = @import("../BlockDevice.zig");
const Device = @import("../../Device.zig");

const NvmeController = @This();

const log = std.log.scoped(.nvme_device);

const nvme_ncqr = 0x2; //number of completion queues requested (+1 is admin cq)
const nvme_nsqr = nvme_ncqr; //number of submission queues requested

pub const NsInfoMap = std.AutoHashMap(u32, id.NsInfo);

pub const ControllerType = enum(u8) {
    io_controller = 1,
    discovery_controller = 2,
    admin_controller = 3,
};
alloctr: std.mem.Allocator,
base: *Device,
type: ControllerType = ControllerType.io_controller, //only IO controller supported

bar: Pcie.Bar = undefined,
msix_cap: Pcie.MsixCap = undefined,

//expected_phase: u1 = 1, //private counter to keep track of the expected phase
mdts_bytes: u32 = 0, // Maximum Data Transfer Size in bytes

ncqr: u16 = nvme_ncqr, //number of completion queues requested - TODO only one cq now
nsqr: u16 = nvme_nsqr, //number of submission queues requested - TODO only one sq now

cq: [nvme_ncqr]NvmeDriver.com.Queue(NvmeDriver.com.CQEntry) = undefined, //+1 for admin cq
//cq: [nvme_ncqr + 1]Queue(CQEntry) = undefined, //+1 for admin
sq: [nvme_nsqr]NvmeDriver.com.Queue(NvmeDriver.com.SQEntry) = undefined, //+1 for admin sq

//slice of NsInfo
ns_info_map: NvmeDriver.NsInfoMap = undefined,

mutex: bool = false,

pub fn init(allocator: std.mem.Allocator, base: *Device) !*NvmeController {
    var self = try allocator.create(NvmeController);
    self.alloctr = allocator;
    self.base = base;
    return self;
}

pub fn deinit(self: *NvmeController) void {
    defer self.alloctr.destroy(self.base);
    self.ns_info_map.deinit();
    const pg_alloctr = heap.page_allocator;
    for (self.cq) |cq| pg_alloctr.free(cq.entries);
    for (self.sq) |sq| pg_alloctr.free(sq.entries);
}

/// Read from the NVMe drive
/// @param allocator : Allocator
/// @param slba : Start Logical Block Address
/// @param nlb : Number of Logical Blocks
pub fn readToOwnedSlice(self: *NvmeController, T: type, allocator: std.mem.Allocator, nsid: u32, slba: u64, nlba: u16) ![]T {
    const ns: id.NsInfo = self.ns_info_map.get(nsid) orelse {
        log.err("Namespace {d} not found", .{nsid});
        return e.NvmeError.InvalidNsid;
    };

    log.debug("Namespace {d} info: {}", .{ nsid, ns });

    if (slba > ns.nsize) return e.NvmeError.InvalidLBA;

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
    _ = iocmd.executeIoNvmCommand(self, @bitCast(io.IoNvmCommandSetCommand{
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
        return e.NvmeError.IONvmReadFailed;
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
pub fn write(self: *NvmeController, T: type, allocator: std.mem.Allocator, nsid: u32, slba: u64, data: []const T) !void {
    const ns: id.NsInfo = self.ns_info_map.get(nsid) orelse {
        log.err("Namespace {d} not found", .{nsid});
        return e.NvmeError.InvalidNsid;
    };

    log.debug("Namespace {d} info: {}", .{ nsid, ns });

    if (slba > ns.nsize) return e.NvmeError.InvalidLBA;

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
    _ = iocmd.executeIoNvmCommand(self, @bitCast(io.IoNvmCommandSetCommand{
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
        return e.NvmeError.IONvmReadFailed;
    };

    //log metadata
    for (metadata) |m| log.debug("Metadata: 0x{x}", .{m});
}

pub fn disableController(self: *NvmeController) void {
    const bar = self.bar;
    toggleController(bar, false);
}

pub fn enableController(self: *NvmeController) void {
    const bar = self.bar;
    toggleController(bar, true);
}

fn toggleController(bar: Pcie.Bar, enable: bool) void {
    var cc = regs.readRegister(regs.CCRegister, bar, .cc);
    log.info("CC register before toggle: {}", .{cc});
    cc.en = if (enable) 1 else 0;
    regs.writeRegister(regs.CCRegister, bar, .cc, cc);

    cc = regs.readRegister(regs.CCRegister, bar, .cc);
    log.info("CC register after toggle: {}", .{cc});

    while (regs.readRegister(regs.CSTSRegister, bar, .csts).rdy != @intFromBool(enable)) {}

    log.info("NVMe controller is {s}", .{if (enable) "enabled" else "disabled"});
}

fn toggleMsi(ctrl: *NvmeController, enable: bool) !void {
    const addr = ctrl.base.addr.pcie;
    var msi_cap: ?Pcie.MsiCap = Pcie.readCapability(Pcie.MsiCap, addr) catch |err| blk: {
        log.err("Can't find MSI capability: {}", .{err});
        break :blk null;
    };
    log.debug("MSI capability: {?}", .{msi_cap});

    if (msi_cap) |*cap| {
        cap.mc.msie = enable;
        try Pcie.writeCapability(Pcie.MsiCap, cap.*, addr);
        log.debug("MSI turned off", .{});
    }
}

pub fn disableMsi(ctrl: *NvmeController) !void {
    try toggleMsi(ctrl, false);
}

fn toggleMsix(ctrl: *NvmeController, enable: bool) !void {
    const addr = ctrl.base.addr.pcie;
    ctrl.msix_cap = try Pcie.readCapability(Pcie.MsixCap, addr);
    log.debug("MSI-X capability pre-modification: {}", .{ctrl.msix_cap});

    if (ctrl.msix_cap.tbir != 0) return e.NvmeError.MsiXMisconfigured; //TODO: it should work on any of the bar but for now we support only bar0

    ctrl.msix_cap.mc.mxe = enable;
    try Pcie.writeCapability(Pcie.MsixCap, ctrl.msix_cap, addr);

    //TODO: remove the following
    ctrl.msix_cap = try Pcie.readCapability(Pcie.MsixCap, addr); //TODO: could be removed
    log.info("MSI-X capability post-modification: {}", .{ctrl.msix_cap});
}

pub fn enableMsix(ctrl: *NvmeController) !void {
    try toggleMsix(ctrl, true);
}
