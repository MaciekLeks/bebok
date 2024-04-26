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
var tmp_ba: BuddyAllocator4kBFrameSize = undefined;
var tmp_ba2: BuddyAllocator4kBFrameSize = undefined;

fn  usizeCmp(a_size: usize, b_size: usize) math.Order {
    return math.order(a_size, b_size);
}

/// Tree based on free region memory size
const AvlTree = zigavl.Tree(usize, *BuddyAllocator4kBFrameSize, usizeCmp);
var arena: std.heap.ArenaAllocator = undefined;
var avl_tree : AvlTree = undefined;

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

           var  ba = try BuddyAllocator4kBFrameSize.init(v_region);
            log.debug("Initialized buddy allocator: unallocated memory size:: 0x{x}, free to allocate memory size: 0x{x}", .{tmp_ba.unalloc_mem_size, tmp_ba.free_mem_size});
            // if (tmp_ba.unalloc_mem_size >= min_region_size_pow2)  {
            //     tmp_ba2 = try BuddyAllocator4kBFrameSize.init(v_region[tmp_ba.free_mem_size..]);
            //     log.debug("Initialized buddy allocator2: unallocated memory size:: 0x{x}, free to allocate memory size: 0x{x}", .{tmp_ba2.unalloc_mem_size, tmp_ba2.free_mem_size});
            // }

            log.debug("[1] free: 0x{x}", .{ba.free_mem_size});
            arena = std.heap.ArenaAllocator.init(ba.allocator());

            const allocator = arena.allocator();
            avl_tree = AvlTree.init(allocator);

            log.debug("Initialized avl tree", .{});

            const heap_ba =  try allocator.create(BuddyAllocator4kBFrameSize);
            heap_ba.* = ba;
            const res1 = try avl_tree.insert(tmp_ba.free_mem_size, heap_ba);
           // const res2 = try avl_tree.insert(2, tmp_ba);
           // const res3 = try avl_tree.insert( 3, tmp_ba);

            //log.debug("[2] free: {x} {x} {x} {x}", .{res1.v.free_mem_size, res2.v.free_mem_size, res3.v.free_mem_size, tmp_ba.free_mem_size});
            log.debug("[2] free: {x}, tree: {any}", .{res1.v.*.free_mem_size, res1.v.*.tree});

        } else return error.NoUsableMemory;
    } else return error.NoMemoryMap;
}

pub fn deinit() void {
    avl_tree.deinit();
    arena.deinit();
}