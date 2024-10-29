const std = @import("std");
const math = std.math;
const limine = @import("limine");
const utils = @import("utils");
const zigavl = @import("zigavl");
const paging = @import("../paging.zig");
const config = @import("config");
const log = std.log.scoped(.pmm);

pub export var mmap_req = limine.MemoryMapRequest{};

pub const page_size = config.mem_page_size;

const min_region_size_pow2 = config.mem_page_size << 1; //one frame_size takes bbtree buffer, so to manage only one frame/page we need at least 2 frames

const BuddyAllocatorPreconfigured = utils.BuddyAllocator(config.mem_bit_tree_max_levels, config.mem_page_size);

fn usizeCmp(a_size: usize, b_size: usize) math.Order {
    return math.order(a_size, b_size);
}
const KeyVaddrSize = struct {
    virt: usize,
    size: usize,
};

// a_key is the key in the get() routine and b_key is the key in the tree
// fn vaddrSizeCmp(a_key: KeyVaddrSize, b_key: KeyVaddrSize) math.Order {
//     // check if b_key is in the range of a_key
//     // if (a_key.vaddr >= b_key.vaddr and a_key.vaddr + a_key.size < b_key.vaddr + b_key.size) return math.Order.eq else if (a_key.vaddr <= b_key.vaddr and a_key.vaddr + a_key.size < b_key.vaddr + b_key.size) return math.Order.lt else return math.Order.gt;
//     // const res = if (a_key.vaddr >= b_key.vaddr and a_key.vaddr + a_key.size < b_key.vaddr + b_key.size) math.Order.eq
//     //     else
//     //         if (a_key.vaddr <= b_key.vaddr and a_key.vaddr + a_key.size < b_key.vaddr + b_key.size) math.Order.lt
//     //         else math.Order.gt;
//     const a_start_gt_b_end = a_key.vaddr >= b_key.vaddr + b_key.size;
//     const a_end_lt_b_end = a_key.vaddr + a_key.size <= b_key.vaddr + b_key.size;
//     const res = if (a_start_gt_b_end and a_end_lt_b_end) math.Order.eq else if (a_key.vaddr + a_key.size <= b_key.vaddr) math.Order.lt else math.Order.gt;
//
//     log.debug("vaddrSizeCmp(): Comparing a_key: 0x{x} -> 0x{x} with b_key: 0x{x} -> 0x{x} => {}, a_start_gt_b_end:{}, a_end_lt_b_end: {}", .{ a_key.vaddr, a_key.vaddr + a_key.size, b_key.vaddr, b_key.vaddr + b_key.size, res, a_start_gt_b_end, a_end_lt_b_end });
//     return res;
// }

fn vaddrSizeCmp(a_key: KeyVaddrSize, b_key: KeyVaddrSize) math.Order {
    if (a_key.virt >= b_key.virt and a_key.virt + a_key.size < b_key.virt + b_key.size) return math.Order.eq else if (a_key.virt <= b_key.virt and a_key.virt + a_key.size < b_key.virt + b_key.size) return math.Order.lt else return math.Order.gt;
}

/// Tree based on free region memory size
const AvlTreeBySize = zigavl.Tree(usize, *BuddyAllocatorPreconfigured, usizeCmp);
const AvlTreeByVaddr = zigavl.Tree(KeyVaddrSize, *BuddyAllocatorPreconfigured, vaddrSizeCmp);
var arena: std.heap.ArenaAllocator = undefined;
var avl_tree_by_size: AvlTreeBySize = undefined;
var avl_tree_by_vaddr: AvlTreeByVaddr = undefined;

pub fn init() !void {
    log.info("PMM initialization", .{});
    defer log.info("PMM initialization done", .{});

    if (mmap_req.response) |mmap_res| {
        var best_region: ?[]u8 = null;
        var best_region_entry_idx: usize = undefined;

        for (mmap_res.entries(), 0..) |entry, i| {
            const size_kb = entry.length / 1024;
            const size_mb = entry.length / 1024 / 1024;
            const size_gb = if (size_mb > 1024) size_mb / 1024 else 0;
            log.debug("init(): Memory map entry {d: >3}: {s: <23} 0x{x} -- 0x{x} of size {d}KB {d}MB ({d}GB)", .{ i, @tagName(entry.kind), entry.base, entry.base + entry.length, size_kb, size_mb, size_gb });
            if (entry.kind == .usable and (best_region == null or best_region.?.len < entry.length)) {
                best_region = @as([*]u8, @ptrFromInt(entry.base))[0..entry.length];
                best_region_entry_idx = i;
            }
        }

        if (best_region) |p_region| {
            const v_region = @as([*]u8, @ptrFromInt(paging.virtFromMME(@intFromPtr(p_region.ptr))))[0..p_region.len];
            log.debug("init(): Best physical region address: 0x{x} -> 0x{x}, constituting virtual region address: 0x{x} -> 0x{x}", .{
                @intFromPtr(p_region.ptr),
                @intFromPtr(p_region.ptr) + p_region.len,
                @intFromPtr(v_region.ptr),
                @intFromPtr(v_region.ptr) + v_region.len,
            });

            var main_buddy_allocator = try BuddyAllocatorPreconfigured.init(v_region);
            log.debug("init(): Initialized buddy allocator: unallocated memory sizex: 0x{x}, free to use memory size: 0x{x}", .{ main_buddy_allocator.unmanaged_mem_size, main_buddy_allocator.free_mem_size });
            arena = std.heap.ArenaAllocator.init(main_buddy_allocator.allocator());

            const arena_allocator = arena.allocator();
            avl_tree_by_size = AvlTreeBySize.init(arena_allocator);
            avl_tree_by_vaddr = AvlTreeByVaddr.init(arena_allocator);

            // we register the best region first and then we register it's unallocated memory
            _ = try avl_tree_by_size.insert(main_buddy_allocator.free_mem_size, main_buddy_allocator);
            _ = try avl_tree_by_vaddr.insert(.{ .virt = main_buddy_allocator.mem_virt, .size = main_buddy_allocator.max_mem_size_pow2 }, main_buddy_allocator);
            try registerRegionZone(@intFromPtr(p_region.ptr) + main_buddy_allocator.free_mem_size, main_buddy_allocator.unmanaged_mem_size);

            // iterate over all regions other than the best one again
            for (mmap_res.entries(), 0..) |entry, i| {
                if (i == best_region_entry_idx) continue;
                if (entry.kind == .usable) try registerRegionZone(entry.base, entry.length);
            }

            std.log.info("init(): PMemory map by size (desc):", .{});
            //var it = avl_tree_by_size.ascendFromStart(); // small size to large size
            var it = avl_tree_by_size.descendFromEnd(); //large size to small size
            while (it.value()) |e| {
                // log free_mem_size in GB, MB, kB and bytes
                const size_gb = e.v.*.free_mem_size / 1024 / 1024 / 1024;
                const size_mb = e.v.*.free_mem_size / 1024 / 1024;
                const size_kb = e.v.*.free_mem_size / 1024;
                log.debug("Free memory size: {d}GB ({d}MB, {d}kB, 0x{x} bytes) at 0x{x} -> 0x{x}", .{ size_gb, size_mb, size_kb, e.v.*.free_mem_size, e.v.*.mem_virt, e.v.*.mem_virt + e.v.*.max_mem_size_pow2 });
                //it.next();
                it.prev();
            }
            std.log.info("init(): PMemory map by vaddr (desc):", .{});
            var it_vadr = avl_tree_by_vaddr.ascendFromStart();
            while (it_vadr.value()) |e| {
                // log free_mem_size in GB, MB, kB and bytes
                const size_gb = e.v.*.free_mem_size / 1024 / 1024 / 1024;
                const size_mb = e.v.*.free_mem_size / 1024 / 1024;
                const size_kb = e.v.*.free_mem_size / 1024;
                log.debug("init(): Free memory size: {d}GB ({d}MB, {d}kB, 0x{x} bytes) at 0x{x} -> 0x{x}", .{ size_gb, size_mb, size_kb, e.v.*.free_mem_size, e.v.*.mem_virt, e.v.*.mem_virt + e.v.*.max_mem_size_pow2 });
                it_vadr.next();
            }
        } else return error.NoUsableMemory;
    } else return error.NoMemoryMap;
}

/// We register at leat one zone per region
fn registerRegionZone(base: usize, len: usize) !void {
    if (len <= min_region_size_pow2) return;
    const v_region = @as([*]u8, @ptrFromInt(paging.virtFromMME(base)))[0..len];
    log.debug("registerRegionZone(): Inserting region zone: 0x{x} -> 0x{x}", .{ @intFromPtr(v_region.ptr), @intFromPtr(v_region.ptr) + v_region.len });
    const zone_buddy_allocator = try BuddyAllocatorPreconfigured.init(v_region);
    _ = try avl_tree_by_size.insert(len, zone_buddy_allocator);
    _ = try avl_tree_by_vaddr.insert(.{ .virt = zone_buddy_allocator.mem_virt, .size = zone_buddy_allocator.max_mem_size_pow2 }, zone_buddy_allocator);
    try registerRegionZone(base + zone_buddy_allocator.free_mem_size, zone_buddy_allocator.unmanaged_mem_size);
}

pub fn deinit() void {
    avl_tree_by_size.deinit();
    arena.deinit();
}

// TODO: implement a more efficient way to find the buddy allocator and updating the tree if free_mem_size changes radically
fn alloc(_: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
    //var it = avl_tree_by_size.ascendFromStart();
    log.debug("///a", .{});
    var it = avl_tree_by_size.descendFromEnd(); //large size to small size
    log.debug("///b", .{});
    const size_pow2 = BuddyAllocatorPreconfigured.minAllocSize(len) catch {
        return null;
    };

    log.debug("///c", .{});
    while (it.value()) |e| {
        log.debug("alloc(): Checking free memory at 0x{x} of total size: 0x{x} bytes, free size: 0x{x} to allocate: 0x{x}, pow2: 0x{x}  ", .{ e.v.*.mem_virt, e.v.*.max_mem_size_pow2, e.v.*.free_mem_size, len, size_pow2 });
        if (e.v.*.free_mem_size >= size_pow2) {
            log.debug("alloc(): Found free memory size: 0x{x} bytes in buddy allocator at 0x{x} of total size: 0x{x} )", .{ e.v.*.free_mem_size, e.v.*.mem_virt, e.v.*.max_mem_size_pow2 });
            const ptr = e.v.*.allocator().rawAlloc(size_pow2, ptr_align, ret_addr); //len is also OK
            if (ptr) |p| {
                defer log.debug("alloc(): Allocated 0x{x} bytes of total allocation 0x{x} bytes at 0x{x}", .{ len, size_pow2, @intFromPtr(p) });
                return p;
            }
        }
        //it.next();
        it.prev();
    }
    return null;
}

fn free(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
    log.debug("free(): Freeing memory at 0x{x}", .{@intFromPtr(buf.ptr)});
    defer log.debug("free(): Freed memory at 0x{x}", .{@intFromPtr(buf.ptr)});
    const key = .{ .virt = @intFromPtr(buf.ptr), .size = buf.len };
    const it = avl_tree_by_vaddr.get(key);
    if (it) |v| {
        const ba = v.*;
        //log.debug("free(): Memory free size before freeing: 0x{x} bytes at 0x{x}", .{ ba.free_mem_size, @intFromPtr(buf.ptr) });
        log.debug("free(): Memory free size before freeing: 0x{x} bytes at 0x{x} in the region at 0x{x}", .{ ba.free_mem_size, @intFromPtr(buf.ptr), v.*.mem_virt });
        v.*.allocator().free(buf);
        log.debug("free(): Memory free size now: 0x{x} bytes", .{ba.free_mem_size});
    } else {
        log.err("free(): Memory at 0x{x} not found", .{@intFromPtr(buf.ptr)});
    }
}

fn resize(_: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
    defer log.debug("resize(): Resized memory at 0x{x} from {d} to {d} bytes", .{ @intFromPtr(buf.ptr), buf.len, new_len });
    const key = .{ .virt = @intFromPtr(buf.ptr), .size = buf.len };
    const it = avl_tree_by_vaddr.get(key);
    if (it) |v| {
        const new_buf = v.*.allocator().rawResize(buf, buf_align, new_len, ret_addr);
        if (new_buf) return true;
    }
    return false;
}

pub const allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .free = free,
    },
};
