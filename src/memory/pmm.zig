const std = @import("std");
const math = std.math;
const limine = @import("limine");
const utils = @import("utils");
const zigavl = @import("zigavl");
const paging = @import("../paging.zig");

const log = std.log.scoped(.pmm);

pub export var mmap_req = limine.MemoryMapRequest{};

const frame_size_pow2 = 4096; //TODO: move to a build config
const min_region_size_pow2 = frame_size_pow2 << 1; //one frame_size takes bbtree buffer, so to manage only one frame/page we need at least 2 frames

const BuddyAllocator4kBFrameSize = utils.BuddyAllocator(32, 4096);

fn usizeCmp(a_size: usize, b_size: usize) math.Order {
    return math.order(a_size, b_size);
}

/// Tree based on free region memory size
const AvlTree = zigavl.Tree(usize, *BuddyAllocator4kBFrameSize, usizeCmp);
var arena: std.heap.ArenaAllocator = undefined;
var avl_tree: AvlTree = undefined;

pub fn init() !void {
    log.debug("Initializing....", .{});
    defer log.debug("Initialized", .{});

    if (mmap_req.response) |mmap_res| {
        var best_region: ?[]u8 = null;
        var best_region_entry_idx: usize = undefined;

        for (mmap_res.entries(), 0..) |entry, i| {
            const size_mb = entry.length / 1024 / 1024;
            const size_gb = if (size_mb > 1024) size_mb / 1024 else 0;
            log.debug("Memory map entry {d: >3}: {s: <23} 0x{x} -- 0x{x} of size {d}MB ({d}GB)", .{ i, @tagName(entry.kind), entry.base, entry.base + entry.length, size_mb, size_gb });
            if (entry.kind == .usable and (best_region == null or best_region.?.len < entry.length)) {
                best_region = @as([*]u8, @ptrFromInt(entry.base))[0..entry.length];
                best_region_entry_idx = i;
            }
        }

        if (best_region) |p_region| {
            const v_region = @as([*]u8, @ptrFromInt(paging.vaddrFromPaddr(@intFromPtr(p_region.ptr))))[0..p_region.len];
            log.debug("Best physical region address: 0x{x} -> 0x{x}, constituting virtual region address: 0x{x} -> 0x{x}", .{
                @intFromPtr(p_region.ptr),
                @intFromPtr(p_region.ptr) + p_region.len,
                @intFromPtr(v_region.ptr),
                @intFromPtr(v_region.ptr) + v_region.len,
            });

            var main_buddy_allocator = try BuddyAllocator4kBFrameSize.init(v_region);
            log.debug("Initialized buddy allocator: unallocated memory size:: 0x{x}, free to use memory size: 0x{x}", .{ main_buddy_allocator.unmanaged_mem_size, main_buddy_allocator.free_mem_size });
            arena = std.heap.ArenaAllocator.init(main_buddy_allocator.allocator());

            const allocator = arena.allocator();
            avl_tree = AvlTree.init(allocator);

            // we register the best region first and then we register it's unallocated memory
            _ = try avl_tree.insert(main_buddy_allocator.free_mem_size, main_buddy_allocator);
            try registerRegionZone(@intFromPtr(p_region.ptr) + main_buddy_allocator.free_mem_size, main_buddy_allocator.unmanaged_mem_size);

            // iterate over all regions other than the best one again
            for (mmap_res.entries(), 0..) |entry, i| {
                if (i == best_region_entry_idx) continue;
                if (entry.kind == .usable) try registerRegionZone(entry.base, entry.length);
            }

            var it = avl_tree.descendFromEnd();
            while (it.value()) |e| {
                // log free_mem_size in GB, MB, kB and bytes
                const size_gb = e.v.*.free_mem_size / 1024 / 1024 / 1024;
                const size_mb = e.v.*.free_mem_size / 1024 / 1024;
                const size_kb = e.v.*.free_mem_size / 1024;
                log.debug("Free memory size: {d}GB ({d}MB, {d}kB, 0x{x} bytes)", .{ size_gb, size_mb, size_kb, e.v.*.free_mem_size });
                it.prev();
            }
        } else return error.NoUsableMemory;
    } else return error.NoMemoryMap;
}

/// We register at leat one zone per region
fn registerRegionZone(base: usize, len: usize) !void {
    if (len <= min_region_size_pow2) return;
    const v_region = @as([*]u8, @ptrFromInt(paging.vaddrFromPaddr(base)))[0..len];
    log.debug("Inserting region zone: 0x{x} -> 0x{x}", .{ @intFromPtr(v_region.ptr), @intFromPtr(v_region.ptr) + v_region.len });
    const zone_buddy_allocator = try BuddyAllocator4kBFrameSize.init(v_region);
    _ = try avl_tree.insert(len, zone_buddy_allocator);
    try registerRegionZone(base + zone_buddy_allocator.free_mem_size, zone_buddy_allocator.unmanaged_mem_size);
}

pub fn deinit() void {
    avl_tree.deinit();
    arena.deinit();
}


