const std = @import("std");
const math = std.math;

const pmm = @import("deps.zig").pmm;
const paging = @import("deps.zig").paging;
const heap = @import("deps.zig").heap;
const Pcie = @import("deps.zig").Pcie;

const NvmeDriver = @import("NvmeDriver.zig");
const NvmeNamespace = @import("NvmeNamespace.zig");

const io = @import("io/io.zig");
const iocmd = @import("io/command.zig");
const id = @import("admin/identify.zig");
const e = @import("errors.zig");
const regs = @import("registers.zig");

const BlockDevice = @import("deps.zig").BlockDevice;
const Device = @import("deps.zig").Device;

const NvmeController = @This();

const log = std.log.scoped(.nvme_controller);

const nvme_ncqr = 0x2; //number of completion queues requested (+1 is admin cq)
const nvme_nsqr = nvme_ncqr; //number of submission queues requested

//pub const NsInfoMap = std.AutoHashMap(u32, id.NsInfo);
pub const NamespaceMap = std.AutoHashMap(u32, *const NvmeNamespace);

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
//pub const NsInfoMap = std.AutoHashMap(u32, id.NsInfo);
//ns_info_map: NvmeDriver.NsInfoMap = undefined,
namespaces: NamespaceMap = undefined,

mutex: bool = false, //TODO: implement real mutex

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
