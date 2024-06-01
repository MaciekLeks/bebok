const limine = @import("limine");
const std = @import("std");
const cpu = @import("cpu.zig");
const config = @import("config");

pub const page_size = config.mem_page_size;

const PageSizeType = enum(u32) {
    size_4k = 4096,
    size_2m = 2 * 1024 * 1024,
    size_1g = 1024 * 1024 * 1024,
};

const PageTable = [512]PageTableEntry;

const PageTableEntry = packed struct(u64) {
    present: bool, // 0
    writable: bool, // 1
    user: bool, // 2
    write_through: bool, // 3
    cache_disable: bool, // 4
    accessed: bool, // 5
    dirty: bool, // 6
    huge: bool, // 7
    global: bool, // 8
    rsvd_a: u3, // 9-11
    aligned_address: u40, // 12-51, 4KiB aligned address
    rsvd_b: u11, // 52-62
    execute_disabled: bool, // 63

    pub fn retrieve_table(self: PageTableEntry) *PageTable {
        return @ptrFromInt(vaddrFromPaddr(self.aligned_address << @bitSizeOf(u12)));
    }
};

/// Holds indexes of all paging tables
/// each table holds indexes of 512 entries, so we need only 9 bytes to store index
/// Offset is 12 bits to address 4KiB page
const PagingIndex = struct {
    lvl4: u9, //pml4
    lvl3: u9, //pdpt
    lvl2: u9, //pd
    lvl1: u9, //pt
    offset: u12,
};

const PagingLevel = enum(u3) {
    lvl4 = 4,
    lvl3 = 3,
    lvl2 = 2,
    lvl1 = 1,
};

pub export var hhdm_request: limine.HhdmRequest = .{};
pub export var paging_mode_request: limine.PagingModeRequest = .{ .mode = .four_level, .flags = 0   }; //default L4 paging
var hhdm_offset: usize = undefined;

const log = std.log.scoped(.paging);



/// Get paging indexes from virtual address
/// It maps 48-bit virtual address to 9-bit indexes of all 52 physical address bits
/// src osdev: "Virtual addresses in 64-bit mode must be canonical, that is,
/// the upper bits of the address must either be all 0s or all 1s.
// For systems supporting 48-bit virtual address spaces, the upper 16 bits must be the same"
pub inline fn pagingIndexFromVaddr(vaddr: usize) PagingIndex {
    return .{
        .lvl4 = @truncate(vaddr >> 39), //48->39
        .lvl3 = @truncate(vaddr >> 30), //39->30
        .lvl2 = @truncate(vaddr >> 21), //30->21
        .lvl1= @truncate(vaddr >> 12), //21->12
        .offset = @truncate(vaddr), //12 bites
    };
}

test pagingIndexFromVaddr {
    try std.testing.expect(PagingIndex{
        .lvl4 = 0,
        .lvl3 = 0,
        .lvl2 = 0,
        .pt = 2,
        .offset = 1,
    }, pagingIndexFromVaddr(0x2001));
}

// Get virtual address from paging indexes
pub inline fn  vaddrFromPageIndex(pidx: PagingIndex) usize {
    const addr = (@as(usize, pidx.lvl4) << 39) | (@as(usize, pidx.lvl3) << 30) | (@as(usize, pidx.lvl2) << 21) | @as(usize, pidx.lvl1) << 12 | pidx.offset;
    switch (addr & @as(usize, 1) << 47)  {
        0 => return addr & 0x7FFF_FFFF_FFFF,
        @as(usize, 1) << 47 => return addr | 0xFFFF_8000_0000_0000,
        else => @panic("Invalid address"),
    }
}

test vaddrFromPageIndex {
    try std.testing.expect(0x2001, vaddrFromPageIndex(.{
        .lvl4 = 0,
        .lvl3 = 0,
        .lvl2 = 0,
        .lvl1 = 2,
        .offset = 1,
    }));
    try std.testing.expect(0xffff800000100000, vaddrFromPageIndex(.{
        .lvl4 = 0x100,
        .lvl3 = 0x0,
        .lvl2 = 0x0,
        .lvl1 = 0x100,
        .offset = 0x0,
    }));
}

inline fn lvl4Table() *PageTable {
    return lvl4_pt;
}

// inline fn lvl4EntryFromVaddr(vaddr: usize) *PageTableEntry {
//     const pidx = pagingIndexFromVaddr(vaddr);
//     return &lvl4Table()[pidx.lvl4];
// }
//
//
// inline fn lvl3TableFromLvl4Id(lvl4_id: u9) *PageTable {
//     return @ptrFromInt(vaddrFromPaddr(lvl4_pt[lvl4_id].aligned_address << @bitSizeOf(u12)));
// }

// inline fn lvl3EntryFromVaddr(vaddr: usize) *PageTableEntry {
//     const pidx = pagingIndexFromVaddr(vaddr);
//     const lvl3_table = lvl3TableFromLvl4Id(pidx.lvl4);
//     return &lvl3_table[pidx.lvl3];
// }
//
// inline fn lvl2TableFromLvl3Id(lvl4_id: u9, lvl3_id: u9) *PageTable {
//     const lvl3_table = lvl3TableFromLvl4Id(lvl4_id);
//     return @ptrFromInt(vaddrFromPaddr(lvl3_table[lvl3_id].aligned_address << @bitSizeOf(u12)));
// }
//
// inline fn lvl2EntryFromVaddr(vaddr: usize) *PageTableEntry {
//     const pidx = pagingIndexFromVaddr(vaddr);
//     const lvl2 = lvl2TableFromLvl3Id(pidx.lvl4, pidx.lvl3);
//     return &lvl2[pidx.lvl2];
// }
//
// inline fn lvl1TableFromLvl2Id(lvl4_id: u9, lvl3_id: u9, lvl2_id: u9) *PageTable {
//     const lvl2_table = lvl2TableFromLvl3Id(lvl4_id, lvl3_id);
//     return @ptrFromInt(vaddrFromPaddr(lvl2_table[lvl2_id].aligned_address << @bitSizeOf(u12)));
// }
//
// inline fn lvl1EntryFromVaddr(vaddr: usize) *PageTableEntry {
//     const pidx = pagingIndexFromVaddr(vaddr);
//     const lvl1_table = lvl1TableFromLvl2Id(pidx.lvl4, pidx.lvl3, pidx.lvl2);
//     return &lvl1_table[pidx.lvl1];
// }
//
fn retrieveTableFromIndex(comptime lvl: PagingLevel, pidx: PagingIndex) *PageTable {
    var current_table: *PageTable = lvl4Table();
    const ti = @intFromEnum(PagingLevel.lvl4);
    inline for ([_]u9{ pidx.lvl4, pidx.lvl3, pidx.lvl2 }, 0..3) |lvl_id, i| {
        if ((ti - i) == @intFromEnum(lvl)) {
            return current_table;
        }
        current_table = current_table[lvl_id].retrieve_table();
    }
    return current_table;
}

fn retrieveTableFromVaddr(comptime lvl: PagingLevel, vaddr: usize) *PageTable {
    const pidx = pagingIndexFromVaddr(vaddr);
    return retrieveTableFromIndex(lvl, pidx);
}

fn retrieveEntryFromVaddr(comptime lvl: PagingLevel, vaddr: usize) *PageTableEntry {
    const pidx = pagingIndexFromVaddr(vaddr);
    const table = retrieveTableFromVaddr(lvl, vaddr);
    return switch (lvl) {
        .lvl4 => return &table[pidx.lvl4],
        .lvl3 => return &table[pidx.lvl3],
        .lvl2 => return &table[pidx.lvl2],
        .lvl1 => return &table[pidx.lvl1],
    };
}


/// Get virtual address from paging indexes using Higher Half Direct Mapping offset
pub inline fn vaddrFromPaddr(paddr: usize) usize {
    return paddr + hhdm_offset;
}

fn lvl4TableFromRegister()  *PageTable {
    return @ptrFromInt(vaddrFromPaddr(cpu.cr3()));
}

var lvl4_pt: *PageTable = undefined;

pub fn init() void {
    log.debug("Initializing...", .{});

    if (page_size != 4096) {
        @panic("Unsupported page size");
    }

    defer log.debug("Initialized", .{});

    if (hhdm_request.response) |hhdm_response| {
        hhdm_offset = hhdm_response.offset;
        log.debug("HHDM offset: 0x{x}", .{hhdm_offset});
        if (hhdm_offset != 0xFFFF_8000_0000_0000)  @panic("Invalid HHDM offset");
    } else  @panic("No HHDM bootloader response available");


    if (paging_mode_request.response) |paging_mode_response| {
        switch (paging_mode_response.mode) {
            .four_level => {
                log.info("4-level paging enabled", .{});
            },
            .five_level => {
                log.info("5-level paging enabled", .{});
            },
        }
    } else  @panic("No paging mode bootloader response available");

    const vaddr =cpu.cr3();
    log.warn("cr3: 0x{x}", .{vaddr});
    lvl4_pt = lvl4TableFromRegister();
   log.info("lvl4: {}, bits=0b{b:0>64}", .{lvl4_pt[0], @as(u64, @bitCast(lvl4_pt[0]))});
    log.info("vaddr: 0x0 -> {any}", .{pagingIndexFromVaddr(0)});
    log.info("vaddr: 0x2000 -> {any}", .{pagingIndexFromVaddr(0x2001)});

    const pidx = pagingIndexFromVaddr(0xffff800000100000);
    log.warn("vaddr: 0xffff800000100000 -> {any}", .{pidx});
    log.warn("vaddr: 0xffff800000100000 -> 0x{x}", .{vaddrFromPageIndex(pidx)});

    //page table entry
    //const pte = pageTableEntryFromPageIndex(pidx);
    //pteFromIndex(pidx);
    //log.warn("pte: 0xffff800000100000 -> {any}", .{pte});

    // const lvl4e = lvl4EntryFromVaddr(0xffff800000100000);
    // log.warn("lvl4e: 0xffff800000100000 -> {any}", .{lvl4e.*});
    // const lvl3e = lvl3EntryFromVaddr(0xffff800000100000);
    // log.warn("lvl3e: 0xffff800000100000 -> {any}", .{lvl3e.*});
    // const lvl2e = lvl2EntryFromVaddr(0xffff800000100000);
    // log.warn("lvl2e: 0xffff800000100000 -> {any}", .{lvl2e.*});
    // const lvl1e = lvl1EntryFromVaddr(0xffff800000100000);
    // log.warn("lvl1e: 0xffff800000100000 -> {any}", .{lvl1e.*});

    //new aproach
    // const lvl4e2 = retrieveEntryFromVaddr(.lvl4, 0xffff800000100001);
    // log.warn("lvl4e2: 0xffff800000100000 -> {any}", .{lvl4e2.*});
    // const lvl3e2 = retrieveEntryFromVaddr(.lvl3, 0xffff800000100001);
    // log.warn("lvl3e2: 0xffff800000100000 -> {any}", .{lvl3e2.*});
    // const lvl2e2 = retrieveEntryFromVaddr(.lvl2, 0xffff800000100001);
    // log.warn("lvl2e2: 0xffff800000100000 -> {}, 0b{b:0>64}", .{lvl2e2.*, @as(u64, @bitCast(lvl2e2.*))});
    // const lvl1e2 = retrieveEntryFromVaddr(.lvl1, 0xffff800000100001);
    // log.warn("lvl1e2: 0xffff800000100000 -> {any}", .{lvl1e2.*});

    const lvl4e = retrieveEntryFromVaddr(.lvl4, 0xffff_8000_fe80_0000);
    log.warn("lvl4e: -> {}", .{lvl4e.*});
     const lvl3e = retrieveEntryFromVaddr(.lvl3, 0xffff_8000_fe80_0000);
     log.warn("lvl3e:  -> {}", .{lvl3e.*});
     const lvl2e = retrieveEntryFromVaddr(.lvl2,0xffff_8000_fe80_0000 );
     log.warn("lvl2e: -> {}", .{lvl2e.*});

    var pi = pagingIndexFromVaddr(0xffff_8000_fe80_0000);
     log.warn("pidx: -> {any}", .{pi});
     pi.lvl2 +=1 ;
    const lvl2t = retrieveTableFromIndex(.lvl2, pi);
     log.warn("lvl2e+1:  -> {}", .{lvl2t[pi.lvl2]});

    const lvl1e = retrieveEntryFromVaddr(.lvl1, 0xffff_8000_fe80_0000);
    log.warn("lvl1e:  -> {}", .{lvl1e.*});
    pi.lvl2 -= 1;
    pi.lvl1 += 1;
    const lvl1t = retrieveTableFromIndex(.lvl1, pi);
    log.warn("lvl1e+1:  -> {}", .{lvl1t[pi.lvl1]});


    log.warn("cr4: 0b{b:0>64}", .{@as(u64, cpu.cr4())});
    log.warn("cr3: 0b{b:0>64}", .{@as(u64, cpu.cr3())});

}
