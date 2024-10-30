const std = @import("std");
const math = std.math;

const pmm = @import("deps.zig").pmm;
const paging = @import("deps.zig").paging;
const heap = @import("deps.zig").heap; //TODO:rmv

const Streamer = @import("deps.zig").BlockDevice.Streamer;

const id = @import("admin/identify.zig");
const e = @import("errors.zig");
const io = @import("io/io.zig");
const iocmd = @import("io/command.zig");

const NvmeController = @import("NvmeController.zig");
const NvmeNamespace = @This();

const log = std.log.scoped(.nvme_namespace);

//Fields
alloctr: std.mem.Allocator, //we use page allocator internally cause LBA size is at least 512 bytes
nsid: u32,
info: id.NsInfo,
ctrl: *NvmeController,

const tmp_len = 32;

pub fn init(allocator: std.mem.Allocator, ctrl: *NvmeController, nsid: u32, info: id.NsInfo) !*NvmeNamespace {
    var self = try allocator.create(NvmeNamespace);
    self.alloctr = allocator;
    self.nsid = nsid;
    self.info = info;
    self.ctrl = ctrl;

    const addr: [*]const u8 = @ptrCast(self);
    log.debug("///660 {*}: {}", .{ self, std.fmt.fmtSliceHexLower(addr[0..tmp_len]) });

    return self;
}

pub fn deinit(self: *NvmeNamespace) void {
    log.debug("///661 - deinit", {});
    self.alloctr.deinit(self);
}

// Yields istels as a Streamer interface
// @return Streamer interface
pub fn streamer(self: *NvmeNamespace) Streamer {
    const vtable = Streamer.VTable{
        .read = read,
        .write = write,
    };
    return Streamer.init(self, vtable);
}

/// Read from the NVMe to owned slice and then copy the data to the user buffer.
/// @param ctx : pointer to NvmeNamespace
/// @param allocator : User allocator to allocate memory for the data buffer
/// @param offset : Offset to read from
/// @param total : Total bytes to read
pub fn read(ctx: *anyopaque, allocator: std.mem.Allocator, offset: usize, total: usize) anyerror![]u8 {
    const self: *const NvmeNamespace = @ptrCast(@alignCast(ctx));

    const addr: [*]const u8 = @ptrCast(self);
    log.debug("///664 {*}: {}", .{ self, std.fmt.fmtSliceHexLower(addr[0..tmp_len]) });

    const lbads_bytes = math.pow(u32, 2, self.info.lbaf[self.info.flbas].lbads);
    const slba = offset / lbads_bytes;
    const nlba: u16 = @intCast(try std.math.divCeil(usize, total, lbads_bytes));
    const slba_offset = offset % lbads_bytes;

    log.debug("Reading from namespace {d} at offset {d}, total: {d}, slba: {d}, nlba: {d}, slba_offset: {d}", .{ self.nsid, offset, total, slba, nlba, slba_offset });

    const data = try self.readInternal(u8, slba, nlba);
    defer self.alloctr.free(data);
    //defer heap.page_allocator.free(data);

    const buf = allocator.alloc(u8, total) catch |err| {
        log.err("Failed to allocate memory for data buffer: {}", .{err});
        return error.OutOfMemory;
    };

    @memcpy(buf, data[slba_offset .. slba_offset + total]);

    return buf;
}

pub fn write(ctx: *anyopaque, offset: usize, buf: []u8) anyerror!void {
    _ = ctx;
    _ = buf;
    _ = offset;
    return error.NotImplemented;

    //self: *const NvmeNamespace, T: type, slba: u64, data: []const T
}

/// Read from the NVMe namespace
/// @param allocator : User allocator
/// @param slba : Start Logical Block Address
/// @param nlb : Number of Logical Blocks
fn readInternal(self: *const NvmeNamespace, comptime T: type, slba: u64, nlba: u16) ![]T {
    // const ns: id.NsInfo = self.ns_info_map.get(nsid) orelse {
    //     log.err("Namespace {d} not found", .{nsid});
    //     return e.NvmeError.InvalidNsid;
    // };
    const addr: [*]const u8 = @ptrCast(self);
    log.debug("///665 {*}: {}", .{ self, std.fmt.fmtSliceHexLower(addr[0..tmp_len]) });

    log.debug("Namespace {d} info: {}", .{ self.nsid, self.info });

    if (slba > self.info.nsze) return e.NvmeError.InvalidLBA;

    const flbaf = self.info.lbaf[self.info.flbas];
    log.debug("LBA Format Index: {d}, LBA Format: {}", .{ self.info.flbas, flbaf });

    const lbads_bytes = math.pow(u32, 2, flbaf.lbads);
    log.debug("LBA Data Size: {d} bytes", .{lbads_bytes});

    //calculate number of pages to allocate
    const total_bytes = nlba * lbads_bytes;
    const page_count = try std.math.divCeil(usize, total_bytes, pmm.page_size);
    log.debug("Number of pages to allocate: {d} to load: {d} bytes", .{ page_count, total_bytes });

    log.debug("///1", .{});
    log.debug("///1 {d}/{d}", .{ total_bytes, @sizeOf(T) });
    log.debug("///1 ={d}", .{total_bytes / @sizeOf(T)});

    //log my alloctr
    //log.debug("///1 self: {any}", .{&self.alloctr});
    //log.debug("///1 self: {any}", .{heap.page_allocator});
    log.debug("///1 alloctr: {any}", .{self.alloctr});
    log.debug("///1 alloctr done", .{});

    // calculate the physical address of the data buffer
    const data = self.alloctr.alloc(T, total_bytes / @sizeOf(T)) catch |err| {
        //const data = heap.page_allocator.alloc(T, total_bytes / @sizeOf(T)) catch |err| {
        log.err("Failed to allocate memory for data buffer: {}", .{err});
        return error.OutOfMemory;
    };

    log.debug("///2", .{});
    @memset(data, 0); //TODO promote to an option, 1 or 0?
    //
    //
    log.debug("///3", .{});

    const prp1_phys = paging.physFromPtr(data.ptr) catch |err| {
        log.err("Failed to get physical address: {}", .{err});
        return error.PageToPhysFailed;
    };

    log.debug("///5", .{});

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

            prp_list = self.alloctr.alloc(usize, entry_count) catch |err| {
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
    defer if (prp_list) |pl| self.alloctr.free(pl);
    log.debug("PRP1: 0x{x}, PRP2: 0x{x}", .{ prp1_phys, prp2_phys });

    // allotate memory for Metadata buffer
    const metadata = self.alloctr.alloc(u8, nlba * flbaf.ms) catch |err| {
        log.err("Failed to allocate memory for metadata buffer: {}", .{err});
        return error.OutOfMemory;
    };
    defer self.alloctr.free(metadata);
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
    _ = iocmd.executeIoNvmCommand(self.ctrl, @bitCast(io.IoNvmCommandSetCommand{
        .read = .{
            .cdw0 = .{
                .opc = .read,
                .cid = 255, //our id
            },
            .nsid = self.nsid,
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
fn writeInternal(self: *const NvmeNamespace, T: type, slba: u64, data: []const T) !void {
    // const ns: id.NsInfo = self.ns_info_map.get(nsid) orelse {
    //     log.err("Namespace {d} not found", .{nsid});
    //     return e.NvmeError.InvalidNsid;
    // };

    log.debug("Namespace {d} info: {}", .{ self.nsid, self.info });

    if (slba > self.info.nsze) return e.NvmeError.InvalidLBA;

    const flbaf = self.info.lbaf[self.info.flbas];
    log.debug("LBA Format Index: {d}, LBA Format: {}", .{ self.info.flbas, flbaf });

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

            prp_list = self.alloctr.alloc(usize, entry_count) catch |err| {
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
    defer if (prp_list) |pl| self.alloctr.free(pl);
    log.debug("PRP1: 0x{x}, PRP2: 0x{x}", .{ prp1_phys, prp2_phys });

    // allotate memory for Metadata buffer
    const metadata = self.alloctr.alloc(u8, nlba * flbaf.ms) catch |err| {
        log.err("Failed to allocate memory for metadata buffer: {}", .{err});
        return error.OutOfMemory;
    };
    defer self.alloctr.free(metadata);
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
    _ = iocmd.executeIoNvmCommand(self.ctrl, @bitCast(io.IoNvmCommandSetCommand{
        .write = .{
            .cdw0 = .{
                .opc = .write,
                .cid = 256, //our id
            },
            .nsid = self.nsid,
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
