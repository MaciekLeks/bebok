//! This is paging solely for 4-Level Paging, but it also supports 4-Kilobyte, 2-Megabyte, and 1-Gigabyte pages.
const limine = @import("limine");
const std = @import("std");
const cpu = @import("cpu.zig");
const config = @import("config");

pub const page_size = config.mem_page_size;
const page_size_4k = 0x1000;
const page_size_2m = 0x200000;
const page_size_1g = 0x40000000;

const PagingMode = enum(u1) {
    four_level = 0,
    five_level = 1,
};

const GenericEntry = usize;

pub fn Cr3Structure(comptime pcid: bool) type {
    if (pcid) {
        return packed struct(GenericEntry) {
            const Self = @This();
            pcid: u12, //0-11
            aligned_address_4kbytes: u40, //12-51- PMPL4|PML5 address
            rsrvd: u12 = 0, //52-63

            pub fn retrieve_table(self: Self, T: type) *T {
                return @ptrFromInt(vaddrFromPaddr(self.aligned_address_4kbytes << @bitSizeOf(u12)));
            }
        };
    } else {
        return packed struct(GenericEntry) {
            const Self = @This();
            ignrd_a: u3, //0-2
            write_though: bool, //3
            cache_disabled: bool, //4
            ignrd_b: u7, //5-11
            aligned_address_4kbytes: u40, //12-51- PMPL4|PML5 address
            rsrvd: u12 = 0, //52-63

            pub fn retrieve_table(self: Self, T: type) *T {
                return @ptrFromInt(vaddrFromPaddr(self.aligned_address_4kbytes << @bitSizeOf(u12)));
            }
        };
    }
}

const Pml4e = PagingStructureEntry(config.mem_page_size, .lvl4);
const Pdpte = PagingStructureEntry(config.mem_page_size, .lvl3);
const Pde = PagingStructureEntry(config.mem_page_size, .lvl2);
const Pte = PagingStructureEntry(config.mem_page_size, .lvl1);
const Pml4 = [512]Pml4e;
const Pdpt = [512]Pdpte;
const Pd = [512]Pde;
const Pt = [512]Pte;

// TODO: usngnamespace does not work in case of the fields
pub fn PagingStructureEntry(comptime ps: u32, comptime lvl: Level) type {
    //return packed struct(GenericEntry) {
    return switch (lvl) {
        .lvl4 => packed struct(GenericEntry) {
            const Self = @This();
            present: bool, //0
            writable: bool, //1
            user: bool, //2
            write_through: bool, //3
            cache_disabled: bool, //4
            accessed: bool, //5
            dirty: bool, //6
            rsrvd_a: u1, //7
            ignrd_a: u3, //8-10
            restart: u1, //11
            aligned_address_4kbytes: u39, //12-50- PML3 address
            rsrvd_b: u1, //51
            ignrd_b: u11, //52-62
            execute_disable: bool, //63

             pub fn retrieve_table(self: Self) []Pdpte {
                return @as(*Pdpt, @ptrFromInt(vaddrFromPaddr(self.aligned_address_4kbytes << @bitSizeOf(u12))));
            }
        },
        // .pdpte1gbytes
        .lvl3 => switch (ps) {
            page_size_1g => packed struct(GenericEntry) {
                const Self = @This();
                present: bool, //0
                writable: bool, //1
                user: bool, //2
                write_through: bool, //3
                cache_disabled: bool, //4
                accessed: bool, //5
                dirty: bool, //6
                huge: bool, //7
                global: bool, //8
                ignrd_a: u2, //9-10
                restart: u1, //11
                pat: u1, //12
                rsrvd_a: u17, //13-29
                aligned_address_1gbyte: u21, //30-50
                rsrvd_b: u1, //51 //must be 0
                ignrd_b: u7, //52-58
                protection_key: u4, //59-62
                execute_disable: bool, //63

                pub fn retrieve_frame_address(self: Self) []GenericEntry {
                    return @as(*[page_size_1g]GenericEntry, @ptrFromInt(vaddrFromPaddr(self.aligned_address_4kbytes << @bitSizeOf(u12))));
                }
            },
            page_size_4k, page_size_2m => packed struct(GenericEntry) {
                const Self = @This();
                present: bool, //0
                writable: bool, //1
                user: bool, //2
                write_through: bool, //3
                cache_disabled: bool, //4
                accessed: bool, //5
                ignrd_a: u1, //6
                hudge: bool, //7
                ignrd_b: u3, //8-10
                restart: u1, //11
                aligned_address_4kbytes: u39, //12-50
                rsrvd_a: u1, //50
                ignr_b: u11, //52-62
                execute_disable: bool, //63

                pub fn retrieve_table(self: Self) []Pde {
                    return @as(*Pd, @ptrFromInt(vaddrFromPaddr(self.aligned_address_4kbytes << @bitSizeOf(u12))));
                }
            },
            else => @compileError("Unsupported page size:" ++ ps),
        },
        .lvl2 => switch (ps) {
            page_size_2m => packed struct(GenericEntry) {
                const Self = @This();
                present: bool, //0
                writable: bool, //1
                user: bool, //2
                write_through: bool, //3
                cache_disabled: bool, //4
                accessed: bool, //5
                dirty: bool, //6
                hudge: bool, //7
                global: bool, //8
                ignrd_a: u2, //9-10
                restart: u1, //11
                pat: u1, //12
                rsrvd_a: u8, //13-20
                aligned_address_2mbytes: u29, //21-50
                rsrvd_b: u1, //51
                ignrd_b: u7, //52-58
                protection_key: u4, //59-62
                execute_disable: bool, //63

                pub fn retrieve_frame_address(self: Self) []GenericEntry {
                    return @as(*[page_size_2m]GenericEntry, @ptrFromInt(vaddrFromPaddr(self.aligned_address_4kbytes << @bitSizeOf(u12))));
                }
            },
            0x1000 => packed struct(GenericEntry) {
                const Self = @This();
                present: bool, //0
                writable: bool, //1
                user: bool, //2
                write_through: bool, //3
                cache_disabled: bool, //4
                accessed: bool, //5
                ignrd_a: bool, //6
                hudge: bool, //7 //must be 0
                ignrd_b: u3, //8-10
                restart: u1, //11
                aligned_address_4kbytes: u39, //12-50
                rsrvd_a: u1, //51-51 //must be 0
                ignrd_c: u11, //52-62
                execute_disable: bool, //63
                pub fn retrieve_table(self: Self) []Pte {
                    return @as(*Pt, @ptrFromInt(vaddrFromPaddr(self.aligned_address_4kbytes << @bitSizeOf(u12))));
                }
            },
            else => @compileError("Unsupported page size:" ++ ps),
        },
        .lvl1 => packed struct(GenericEntry) {
            const Self = @This();
            present: bool, //0
            writable: bool, //1
            user: bool, //2
            write_through: bool, //3
            cache_disabled: bool, //4
            accessed: bool, //5
            dirty: bool, //6
            pat: u1, //7
            global: bool, //8
            ignrd_a: u2, //9-10
            restart: u1, //11
            aligned_address_4kbytes: u39, //12-50
            rsrvd_a: u1, //51-51 //must be 0
            ignrd_b: u7, //52-58
            protection_key: u4, //59-62
            execute_disable: bool, //63

            pub fn retrieve_frame_address(self: Self) []GenericEntry{
                return @as(*[page_size_4k]GenericEntry, @ptrFromInt(vaddrFromPaddr(self.aligned_address_4kbytes << @bitSizeOf(u12))));
            }
        },
    };
}

// const PageTableEntry = packed struct(u64) {
//     present: bool, // 0
//     writable: bool, // 1
//     user: bool, // 2
//     write_through: bool, // 3
//     cache_disable: bool, // 4
//     accessed: bool, // 5
//     dirty: bool, // 6
//     huge: bool, // 7
//     global: bool, // 8
//     rsvd_a: u3, // 9-11
//     aligned_address: u40, // 12-51, 4KiB aligned address
//     rsvd_b: u11, // 52-62
//     execute_disabled: bool, // 63
//
//     pub fn retrieve_table(self: PageTableEntry) *PageTable {
//         return @ptrFromInt(vaddrFromPaddr(self.aligned_address << @bitSizeOf(u12)));
//     }
// };

/// Holds indexes of all paging tables
/// each table holds indexes of 512 entries, so we need only 9 bytes to store index
/// Offset is 12 bits to address 4KiB page
const PagingIndex = struct {
    pml4t_idx: u9, //pml4
    pdpt_idx: u9, //pdpt
    pdt_idx: u9, //pd
    pt_idx: u9, //pt
    offset: u12,
};

const Level = enum(u3) {
    lvl4 = 4,
    lvl3 = 3,
    lvl2 = 2,
    lvl1 = 1,
};

pub export var hhdm_request: limine.HhdmRequest = .{};
pub export var paging_mode_request: limine.PagingModeRequest = .{ .mode = .four_level, .flags = 0 }; //default L4 paging
var hhdm_offset: usize = undefined;

const log = std.log.scoped(.paging);

/// Get paging indexes from virtual address
/// It maps 48-bit virtual address to 9-bit indexes of all 52 physical address bits
/// src osdev: "Virtual addresses in 64-bit mode must be canonical, that is,
/// the upper bits of the address must either be all 0s or all 1s.
// For systems supporting 48-bit virtual address spaces, the upper 16 bits must be the same"
pub inline fn pagingIndexFromVaddr(vaddr: usize) PagingIndex {
    return .{
        .pml4t_idx = @truncate(vaddr >> 39), //48->39
        .pdpt_idx = @truncate(vaddr >> 30), //39->30
        .pdt_idx = @truncate(vaddr >> 21), //30->21
        .pt_idx = @truncate(vaddr >> 12), //21->12
        .offset = @truncate(vaddr) //12 bites
    };
}

test pagingIndexFromVaddr {
    try std.testing.expect(PagingIndex{
        .lvl4 = 0,
        .lvl3 = 0,
        .lvl2 = 0,
        .pt = 2,
        .offset = 1
    }, pagingIndexFromVaddr(0x2001));
}

// Get virtual address from paging indexes
pub inline fn vaddrFromPageIndex(pidx: PagingIndex) usize {
    const addr = (@as(usize, pidx.plm4t_idx) << 39) | (@as(usize, pidx.pdpt_idx) << 30) | (@as(usize, pidx.pdt_idx) << 21) | @as(usize, pidx.pt_idx) << 12 | pidx.offset;
    switch (addr & @as(usize, 1) << 47) {
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
        .offset = 1
    }));
    try std.testing.expect(0xffff800000100000, vaddrFromPageIndex(.{
        .lvl4 = 0x100,
        .lvl3 = 0x0,
        .lvl2 = 0x0,
        .lvl1 = 0x100,
        .offset = 0x0
    }));
}

inline fn lvl4Table() []Pml4e {
    return pml4t;
}

// fn retrieveTableFromIndex(EntryType: type, comptime lvl: Level, pidx: PagingIndex) []EntryType {
//     var current_table = lvl4Table();
//     const ti = @intFromEnum(Level.lvl4);
//     inline for ([_]u9{ pidx.plm4t_idx, pidx.pdpt_idx, pidx.pdt_idx }, 0..3) |lvl_id, i| {
//         if ((ti - i) == @intFromEnum(lvl)) {
//             return current_table;
//         }
//         current_table = current_table[lvl_id].retrieve_table();
//     }
//     return current_table;
// }

inline fn retrieveTableFromIndex(comptime lvl: Level, pidx: PagingIndex) switch (lvl) {
    .lvl4 => []Pml4e,
    .lvl3 => []Pdpte,
    .lvl2 => []Pde,
    .lvl1 => []Pte  ,
} {
    switch (lvl) {
        .lvl4 => {
            return lvl4Table();
        },
        .lvl3 => {
            return retrieveTableFromIndex(.lvl4, pidx)[pidx.pml4t_idx].retrieve_table();
        },
        .lvl2 => {
            return  retrieveTableFromIndex(.lvl3, pidx)[pidx.pdpt_idx].retrieve_table();
        },
        .lvl1 => {
            return retrieveTableFromIndex(.lvl2, pidx)[pidx.pdt_idx].retrieve_table();
        },
    }
}

fn retrieveTableFromVaddr(EntryType: type,  comptime lvl: Level, vaddr: usize) []EntryType {
    const pidx = pagingIndexFromVaddr(vaddr);
    return retrieveTableFromIndex(lvl, pidx);
}

fn retrieveEntryFromVaddr(EntryType: type, comptime pm: PagingMode, comptime ps: u32, comptime lvl: Level, vaddr: usize) *EntryType {
    const pidx = pagingIndexFromVaddr(vaddr);
    const table = retrieveTableFromVaddr(EntryType, lvl, vaddr);
    return switch (pm) {
        .four_level => switch (ps) {
            page_size_4k => switch (lvl) {
                .lvl4 => &table[pidx.pml4t_idx],
                .lvl3 => &table[pidx.pdpt_idx],
                .lvl2 => &table[pidx.pdt_idx],
                .lvl1 => &table[pidx.pt_idx],
            },
            page_size_2m => switch (lvl) {
                .lvl4 => &table[pidx.pml4t_idx],
                .lvl3 => &table[pidx.pdpt_idx],
                .lvl2 => &table[pidx.pdt_idx],
                else => @compileError("Unsupported page level for 2-MByte page."),
            },
            page_size_1g => switch (lvl) {  // Poprawiona wartość rozmiaru strony na format heksadecymalny
                .lvl4 => &table[pidx.pml4t_idx],
                .lvl3 => &table[pidx.pdpt_idx],
                else => @compileError("Unsupported page level for 1-GByte page."),
            },
            else => @compileError("Unsupported page size"),
        },
        else => @compileError("Unsupported 5-Level Paging mode"),
    };
}

inline fn entryFromVaddr(comptime lvl: Level, vaddr: usize) *PagingStructureEntry(page_size, lvl) {
    return  retrieveEntryFromVaddr(PagingStructureEntry(page_size, lvl), .four_level, page_size, lvl, vaddr);
}

/// Get virtual address from paging indexes using Higher Half Direct Mapping offset
pub inline fn vaddrFromPaddr(paddr: usize) usize {
    return paddr + hhdm_offset;
}

//const Pml4t = [512]Pml4e;
fn lvl4TableFromRegister() []Pml4e {
    const cr3_formatted: Cr3Structure(false) = @bitCast(cpu.cr3());
    log.warn("cr3_formatted: {}", .{cr3_formatted});
    log.warn("cr3_formatted: 0x{x:0>16}", .{@as(u64, cr3_formatted.aligned_address_4kbytes)});
    log.warn("cr3: 0x{x:0>16}", .{@as(u64, cpu.cr3())});
    log.warn("cr3_formated_ptr: 0b{x:0>64}", .{@intFromPtr(cr3_formatted.retrieve_table(Pml4e))});
    //    return @ptrFromInt(vaddrFromPaddr(cr3_formatted.aligned_address_4kbytes << @bitSizeOf(u12)));
    return cr3_formatted.retrieve_table(Pml4);
}

var pml4t: []Pml4e = undefined;

pub fn init() void {
    log.debug("Initializing...", .{});

    // if (page_size != 4096) {
    //     @panic("Unsupported page size");
    // }

    defer log.debug("Initialized", .{});

    if (hhdm_request.response) |hhdm_response| {
        hhdm_offset = hhdm_response.offset;
        log.debug("HHDM offset: 0x{x}", .{hhdm_offset});
        if (hhdm_offset != 0xFFFF_8000_0000_0000) @panic("Invalid HHDM offset");
    } else @panic("No HHDM bootloader response available");

    if (paging_mode_request.response) |paging_mode_response| {
        switch (paging_mode_response.mode) {
            .four_level => {
                log.info("4-level paging enabled", .{});
            },
            .five_level => {
                log.info("5-level paging enabled", .{});
            },
        }
    } else @panic("No paging mode bootloader response available");

    const vaddr = cpu.cr3();
    log.warn("cr3: 0x{x}", .{vaddr});
    pml4t = lvl4TableFromRegister();

    log.warn("lvl4: {}", .{pml4t[0]});

    //const lvl4e = retrieveEntryFromVaddr(PagingStructureEntry(page_size, .lvl4), .four_level, page_size, .lvl4, 0xffff_8000_fe80_0000);
    const lvl4e = entryFromVaddr( .lvl4, 0xffff_8000_fe80_0000);
    log.warn("lvl4e(pml4): -> {}", .{lvl4e.*});
     const lvl3e = entryFromVaddr(.lvl3, 0xffff_8000_fe80_0000);
     log.warn("lvl3e(pdpt):  -> {}", .{lvl3e.*});
     const lvl2e = entryFromVaddr(.lvl2, 0xffff_8000_fe80_0000);
     log.warn("lvl2e(pd):  -> {}, pfn={*}", .{lvl2e.*, lvl2e.retrieve_table()});
    const lvl1e = entryFromVaddr(.lvl1, 0xffff_8000_fe80_0000);
    log.warn("lvl1e(pt: -> {}, pfn= {*}", .{lvl1e.*, lvl1e.retrieve_frame_address()});

    // var pi = pagingIndexFromVaddr(0xffff_8000_fe80_0000);
    // log.warn("pidx: -> {any}", .{pi});
    // pi.lvl2 += 1;
    // const lvl2t = retrieveTableFromIndex(.lvl2, pi);
    // log.warn("lvl2e+1:  -> {}", .{lvl2t[pi.lvl2]});
    //
    // const lvl1e = retrieveEntryFromVaddr(.lvl1, 0xffff_8000_fe80_0000);
    // log.warn("lvl1e:  -> {}", .{lvl1e.*});
    // pi.lvl2 -= 1;
    // pi.lvl1 += 1;
    // const lvl1t = retrieveTableFromIndex(.lvl1, pi);
    // log.warn("lvl1e+1:  -> {}", .{lvl1t[pi.lvl1]});

    log.warn("cr4: 0b{b:0>64}", .{@as(u64, cpu.cr4())});
    log.warn("cr3: 0b{b:0>64}", .{@as(u64, cpu.cr3())});
}
