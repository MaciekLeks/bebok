const std = @import("std");
const limine = @import("limine");
const utils = @import("utils");
const paging = @import("../paging.zig");

const log = std.log.scoped(.pmm);

pub export var mmap_req = limine.MemoryMapRequest{};

const BuddyAllocator4kBFrameSize = utils.BuddyAllocator(32, 4096);
var tmp_ba: BuddyAllocator4kBFrameSize = undefined;

pub fn init() !void {
    log.debug("Initializing....", .{});
    defer log.debug("Initialized", .{});

    if (mmap_req.response) |mmap_res| {
        var best_region: ?[]u8 = null;

        for (mmap_res.entries(), 0..) |entry, i| {
            const size_mb = entry.length / 1024 / 1024;
            const size_gb = if (size_mb > 1024) size_mb / 1024 else 0;
            log.debug("Memory map entry {d: >3}: {s: <23} 0x{x} -- 0x{x} of size {d}MB ({d}GB)", .{ i, @tagName(entry.kind), entry.base, entry.base + entry.length, size_mb, size_gb});
            if (entry.kind == .usable and (best_region == null or best_region.?.len < entry.length)) best_region = @as([*]u8, @ptrFromInt(entry.base))[0..entry.length];
        }

        if (best_region) |p_region| {
            const v_region = @as([*]u8, @ptrFromInt(paging.vaddrFromPaddr(@intFromPtr(p_region.ptr))))[0..p_region.len];
            log.debug("Best physical region address: 0x{x} -> 0x{x}, constituting virtual region address: 0x{x} -> 0x{x}", .{
                @intFromPtr(p_region.ptr),
                @intFromPtr(p_region.ptr) + p_region.len,
                @intFromPtr(v_region.ptr),
                @intFromPtr(v_region.ptr) + v_region.len,
            });

            tmp_ba = try BuddyAllocator4kBFrameSize.init(v_region);
            log.debug("Initialized buddy allocator: unallocated memory size:: 0x{x}, free to allocate memory size: 0x{x}", .{tmp_ba.unalloc_mem_size, tmp_ba.free_mem_size});
        } else return error.NoUsableMemory;
    } else return error.NoMemoryMap;
}
