const std = @import("std");
const math = std.math;

const pmm = @import("mem").pmm;
const paging = @import("core").paging;
const heap = @import("mem").heap; //TODO:rmv

const Device = @import("devices").Device;
const BlockDevice = @import("devices").BlockDevice;
const Streamer = @import("devices").BlockDevice.Streamer;
const PartitionScheme = @import("devices").PartitionScheme;

const id = @import("admin/identify.zig");
const e = @import("errors.zig");
const io = @import("io/io.zig");
const iocmd = @import("io/command.zig");

const NvmeController = @import("NvmeController.zig");
const NvmeNamespace = @This();

const log = std.log.scoped(.nvme_namespace);

//Fields
alloctr: std.mem.Allocator, //we use page allocator internally cause LBA size is at least 512 bytes
block_device: BlockDevice,
nsid: u32,
info: id.NsInfo,
ctrl: *NvmeController,

// Device interface vtable for NvmeController
const device_vtable = Device.VTable{
    .deinit = deinit,
};

const block_device_vtable = BlockDevice.VTable{
    .streamer = streamer,
};

pub fn init(allocator: std.mem.Allocator, ctrl: *NvmeController, nsid: u32, info: *const id.NsInfo) !*NvmeNamespace {
    const self = try allocator.create(NvmeNamespace);
    self.* = .{
        .alloctr = heap.page_allocator, //we use page allocator internally cause LBA size is at least 512
        .block_device = .{
            .device = .{ .kind = Device.Kind.block, .vtable = &device_vtable },
            .state = .{
                .partition_scheme = null,
                .slba = 0,
                .nlba = info.nsze,
                .lbads = math.pow(u32, 2, info.lbaf[info.flbas].lbads),
            },
            .vtable = &block_device_vtable,
        },
        .nsid = nsid,
        .info = info.*,
        .ctrl = ctrl,
    };

    return self;
}

// pub fn detectPartitionScheme(self: *const NvmeNamespace) !void {
//     const scheme = try PartitionScheme.init(self.alloctr, self.streamer());
//     log.debug("Partition scheme detected: {any}", .{scheme});
//     self.state.partition_scheme = scheme;
// }

pub fn fromDevice(dev: *Device) *NvmeNamespace {
    const block_device: *BlockDevice = BlockDevice.fromDevice(dev);
    return @alignCast(@fieldParentPtr("block_device", block_device));
}

pub fn fromBlockDevice(block_device: *BlockDevice) *NvmeNamespace {
    return @alignCast(@fieldParentPtr("block_device", block_device));
}

pub fn deinit(dev: *Device) void {
    const block_device: *BlockDevice = BlockDevice.fromDevice(dev);
    //const self: *NvmeNamespace = @alignCast(@fieldParentPtr("block_device", block_device));
    const self: *NvmeNamespace = fromBlockDevice(block_device);

    block_device.deinit(); //free partition if any
    self.alloctr.destroy(self);
}

// Yields istels as a Streamer interface
// @return Streamer interface
pub fn streamer(bdev: *BlockDevice) Streamer {
    const self = fromBlockDevice(bdev);
    const vtable = Streamer.VTable{
        .read = readInternal,
        .write = writeInternal,
        .calculate = calculateInternal,
    };
    return Streamer.init(self, vtable);
}

/// Calculate the LBA from the offset and total bytes to read/write
pub fn calculateInternal(ctx: *const anyopaque, offset: usize, total: usize) !Streamer.LbaPos {
    const self: *const NvmeNamespace = @ptrCast(@alignCast(ctx));

    const lbads_bytes = math.pow(u32, 2, self.info.lbaf[self.info.flbas].lbads); //TODO: change to self.block_device.state.lbads
    const slba = offset / lbads_bytes;
    const nlba: u16 = @intCast(try std.math.divCeil(usize, total, lbads_bytes));
    const slba_offset = offset % lbads_bytes;

    return .{ .slba = slba, .nlba = nlba, .slba_offset = slba_offset };
}

/// Read from the NVMe namespace
/// @param allocator : User allocator
/// @param slba : Start Logical Block Address
/// @param nlb : Number of Logical Blocks
pub fn readInternal(ctx: *const anyopaque, allocator: std.mem.Allocator, slba: u64, nlba: u16) ![]u8 {
    const self: *const NvmeNamespace = @ptrCast(@alignCast(ctx));

    log.debug("Namespace {d} info: {}", .{ self.nsid, self.info });

    if (slba + nlba - 1 > self.info.nsze) return e.NvmeError.InvalidLBA;

    const flbaf = self.info.lbaf[self.info.flbas];
    log.debug("LBA Format Index: {d}, LBA Format: {}", .{ self.info.flbas, flbaf });

    const lbads_bytes = math.pow(u32, 2, flbaf.lbads); //TODO: change to self.block_device.state.lbads
    log.debug("LBA Data Size: {d} bytes", .{lbads_bytes});

    //calculate number of pages to allocate
    const total_bytes = nlba * lbads_bytes;
    const page_count = try std.math.divCeil(usize, total_bytes, pmm.page_size);
    log.debug("Number of pages to allocate: {d} to load: {d} bytes", .{ page_count, total_bytes });

    // calculate the physical address of the data buffer
    const data = allocator.alloc(u8, total_bytes) catch |err| {
        //const data = heap.page_allocator.alloc(T, total_bytes / @sizeOf(T)) catch |err| {
        log.err("Failed to allocate memory for data buffer: {}", .{err});
        return error.OutOfMemory;
    };

    @memset(data, 0);
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

    // allocate memory for Metadata buffer
    var metadata: ?[]u8 = null;
    const mptr_phys = if (flbaf.ms > 0) blk: {
        metadata = allocator.alloc(u8, nlba * flbaf.ms) catch |err| {
            log.err("Failed to allocate memory for metadata buffer: {}", .{err});
            return error.OutOfMemory;
        };
        @memset(metadata.?, 0);

        break :blk paging.physFromPtr(metadata.?.ptr) catch |err| {
            log.err("Failed to get physical address: {}", .{err});
            return error.PageToPhysFailed;
        };
    } else 0;

    // choose sqn and cqn for the operation
    // TODO: implwement the logic to choose the right queue
    const sqn = 1;
    const cqn = 1;

    log.debug("Executing I/O NVM Command Set Read command", .{});
    _ = iocmd.executeIoNvmCommand(self.ctrl, @bitCast(io.IoNvmCommandSetCommand{
        .read = .{
            .cdw0 = .{
                .opc = .read,
                .cid = self.ctrl.nextComandId(), //our id
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
            .fua = 1, //force unit access (read from the device)
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
    if (metadata) |md| {
        for (md) |d| log.debug("Metadata: 0x{x}", .{d});
        defer allocator.free(metadata.?);
    }

    return data;
}

/// Write to the NVMe drive
/// @param allocator : Allocator to allocate memory for PRP list
/// @param slba : Start Logical Block Address
/// @param data : Data to write
pub fn writeInternal(ctx: *const anyopaque, allocator: std.mem.Allocator, slba: u64, data: []const u8) !void {
    const self: *const NvmeNamespace = @ptrCast(@alignCast(ctx));

    log.debug("Namespace {d} info: {}", .{ self.nsid, self.info });

    if (slba > self.info.nsze) return e.NvmeError.InvalidLBA;

    const flbaf = self.info.lbaf[self.info.flbas];
    log.debug("LBA Format Index: {d}, LBA Format: {}", .{ self.info.flbas, flbaf });

    const lbads_bytes = math.pow(u32, 2, flbaf.lbads);
    log.debug("LBA Data Size: {d} bytes", .{lbads_bytes});

    // nlba = number of logical blocks to write
    const data_total_bytes = data.len;
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

    // allocate memory for Metadata buffer
    var metadata: ?[]u8 = null;
    const mptr_phys = if (flbaf.ms > 0) blk: {
        metadata = allocator.alloc(u8, nlba * flbaf.ms) catch |err| {
            log.err("Failed to allocate memory for metadata buffer: {}", .{err});
            return error.OutOfMemory;
        };
        @memset(metadata.?, 0);

        break :blk paging.physFromPtr(metadata.?.ptr) catch |err| {
            log.err("Failed to get physical address: {}", .{err});
            return error.PageToPhysFailed;
        };
    } else 0;

    // choose sqn and cqn for the operation
    // TODO: implwement the logic to choose the right queue
    const sqn = 1;
    const cqn = 1;

    log.debug("Executing I/O NVM Command Set Read command", .{});
    _ = iocmd.executeIoNvmCommand(self.ctrl, @bitCast(io.IoNvmCommandSetCommand{
        .write = .{
            .cdw0 = .{
                .opc = .write,
                .cid = self.ctrl.nextComandId(), //our id
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
            .fua = 1, //force unit access (no caching)
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
    if (metadata) |md| {
        for (md) |d| log.debug("Metadata: 0x{x}", .{d});
        defer allocator.free(metadata.?);
    }
}
