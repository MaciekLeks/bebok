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

const Pml4e = PagingStructureEntry(config.mem_page_size, .pml4);
const Pdpte = PagingStructureEntry(config.mem_page_size, .pdpt);
const Pde = PagingStructureEntry(config.mem_page_size, .pd);
const Pte = PagingStructureEntry(config.mem_page_size, .pt);
const Pml4 = [512]Pml4e;
const Pdpt = [512]Pdpte;
const Pd = [512]Pde;
const Pt = [512]Pte;

// TODO: usngnamespace does not work in case of the fields
pub fn PagingStructureEntry(comptime ps: u32, comptime lvl: Level) type {
    //return packed struct(GenericEntry) {
    return switch (lvl) {
        .pml4 => packed struct(GenericEntry) {
            const Self = @This();
            present: bool = false, //0
            writable: bool = false, //1
            user: bool = false, //2
            write_through: bool = false, //3
            cache_disabled: bool = false, //4
            accessed: bool = false, //5
            dirty: bool = false, //6
            rsrvd_a: u1 = 0, //7
            ignrd_a: u3 = 0, //8-10
            restart: u1 = 0, //11
            aligned_address_4kbytes: u39, //12-50- PML3 address
            rsrvd_b: u1 = 0, //51
            ignrd_b: u11 = 0, //52-62
            execute_disable: bool = false, //63

            pub fn retrieve_table(self: Self) []Pdpte {
                return @as(*Pdpt, @ptrFromInt(vaddrFromPaddr(self.aligned_address_4kbytes << @bitSizeOf(u12))));
            }
        },
        // .pdpte1gbytes
        .pdpt => switch (ps) {
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
                present: bool = false, //0
                writable: bool = false, //1
                user: bool = false, //2
                write_through: bool = false, //3
                cache_disabled: bool = false, //4
                accessed: bool = false, //5
                ignrd_a: u1 = 0, //6
                hudge: bool = false, //7
                ignrd_b: u3 = 0, //8-10
                restart: u1 = 0, //11
                aligned_address_4kbytes: u39, //12-50
                rsrvd_a: u1 = 0, //50
                ignr_b: u11 = 0, //52-62
                execute_disable: bool = false, //63

                pub fn retrieve_table(self: Self) []Pde {
                    return @as(*Pd, @ptrFromInt(vaddrFromPaddr(self.aligned_address_4kbytes << @bitSizeOf(u12))));
                }
            },
            else => @compileError("Unsupported page size:" ++ ps),
        },
        .pd => switch (ps) {
            page_size_2m => packed struct(GenericEntry) {
                const Self = @This();
                present: bool = false, //0
                writable: bool = false, //1
                user: bool = false, //2
                write_through: bool = false, //3
                cache_disabled: bool = false, //4
                accessed: bool = false, //5
                dirty: bool = false, //6
                hudge: bool = false, //7
                global: bool = false, //8
                ignrd_a: u2 = 0, //9-10
                restart: u1 = 0, //11
                pat: u1 = 0, //12
                rsrvd_a: u8 = 0, //13-20
                aligned_address_2mbytes: u29, //21-50
                rsrvd_b: u1 = 0, //51
                ignrd_b: u7 = 0, //52-58
                protection_key: u4 = 0, //59-62
                execute_disable: bool = false, //63

                pub fn retrieve_frame_address(self: Self) []GenericEntry {
                    return @as(*[page_size_2m]GenericEntry, @ptrFromInt(vaddrFromPaddr(self.aligned_address_4kbytes << @bitSizeOf(u12))));
                }
            },
            page_size_4k => packed struct(GenericEntry) {
                const Self = @This();
                present: bool = false, //0
                writable: bool = false, //1
                user: bool = false, //2
                write_through: bool = false, //3
                cache_disabled: bool = false, //4
                accessed: bool = false, //5
                ignrd_a: bool = false, //6
                hudge: bool = false , //7 //must be 0
                ignrd_b: u3 = 0, //8-10
                restart: u1 = 0, //11
                aligned_address_4kbytes: u39, //12-50
                rsrvd_a: u1 = 0, //51-51 //must be 0
                ignrd_c: u11 = 0, //52-62
                execute_disable: bool = true, //63
                pub fn retrieve_table(self: Self) []Pte {
                    return @as(*Pt, @ptrFromInt(vaddrFromPaddr(self.aligned_address_4kbytes << @bitSizeOf(u12))));
                }
            },
            else => @compileError("Unsupported page size:" ++ ps),
        },
        .pt => packed struct(GenericEntry) {
            const Self = @This();
            present: bool = false, //0
            writable: bool = false, //1
            user: bool = false, //2
            write_through: bool = false, //3
            cache_disabled: bool = false, //4
            accessed: bool = false, //5
            dirty: bool = false, //6
            pat: u1 = 0, //7
            global: bool = false, //8
            ignrd_a: u2 = 0, //9-10
            restart: u1 = 0, //11
            aligned_address_4kbytes: u39, //12-50
            rsrvd_a: u1 = 0, //51-51 //must be 0
            ignrd_b: u7 = 0, //52-58
            protection_key: u4 = 0, //59-62
            execute_disable: bool = false, //63

            pub fn retrieve_frame_address(self: Self) []GenericEntry {
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
const Index = struct {
    pml4_idx: u9, //pml4
    pdpt_idx: u9, //pdpt
    pd_idx: u9, //pd
    pt_idx: u9, //pt
    //offset: u12,
    offset: u30, //12 bites for 4k pages, 21 for 2m pages, 30 for 1g pages
};

const Level = enum(u3) {
    pml4 = 4,
    pdpt = 3,
    pd = 2,
    pt = 1,
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
pub inline fn indexFromVaddr(vaddr: usize) Index {
    return .{
        .pml4_idx = @truncate(vaddr >> 39), //47->39
        .pdpt_idx = @truncate(vaddr >> 30), //39->30
        .pd_idx = @truncate(vaddr >> 21), //30->21
        .pt_idx = @truncate(vaddr >> 12), //21->12
        .offset = @truncate(vaddr), //12 bites
    };
}

test indexFromVaddr {
    try std.testing.expect(Index{ .lvl4 = 0, .lvl3 = 0, .lvl2 = 0, .pt = 2, .offset = 1 }, indexFromVaddr(0x2001));
}

// Get virtual address from paging indexes
pub inline fn vaddrFromIndex(pidx: Index) usize {
    const addr = (@as(usize, pidx.pml4_idx) << 39) | (@as(usize, pidx.pdpt_idx) << 30) | (@as(usize, pidx.pd_idx) << 21) | @as(usize, pidx.pt_idx) << 12 | pidx.offset;
    switch (addr & @as(usize, 1) << 47) {
        0 => return addr & 0x7FFF_FFFF_FFFF,
        @as(usize, 1) << 47 => return addr | 0xFFFF_8000_0000_0000,
        else => @panic("Invalid address"),
    }
}

test vaddrFromIndex {
    try std.testing.expect(0x2001, vaddrFromIndex(.{ .lvl4 = 0, .lvl3 = 0, .lvl2 = 0, .lvl1 = 2, .offset = 1 }));
    try std.testing.expect(0xffff800000100000, vaddrFromIndex(.{ .lvl4 = 0x100, .lvl3 = 0x0, .lvl2 = 0x0, .lvl1 = 0x100, .offset = 0x0 }));
}

pub fn physFromVirt(vaddr: usize) usize {
    const pidx = indexFromVaddr(vaddr);

    switch (page_size) {
        //TODO uncomment when 4k pages are supported
        // page_size_4k => {
        //     const pt = (510 << 39) | @as(usize, pidx.pdpt_idx) << 30 | @as(usize, pidx.pd_idx) << 12;
        //     const table: [*]Pte = @ptrFromInt(pt);
        //     return (@as(usize, table[pidx.pt_idx].aligned_address_4kbytes) <<  12) + pidx.offset;
        // },
        page_size_4k,  page_size_2m => {
            var tmp_pidx = pidx;
            _ = &tmp_pidx;
            const pd = (510 << 39) | (510) << 30 | @as(usize, pidx.pd_idx) << 21;
            const pde: *Pde = @ptrFromInt(pd);
            return (@as(usize, pde.aligned_address_4kbytes) <<  12) + pidx.offset;
        },
        page_size_1g => {
            const pdpt = (510 << 39) | (510) << 30 | (510) << 21;
            const table: [*]Pdpte = @ptrFromInt(pdpt);
            return (@as(u64, table[pidx.pdpt_idx].aligned_address_4kbytes) <<  30) + pidx.offset;
        },
        else => @compileError("Unsupported page size"),
    }
}


inline fn lvl4Table() []Pml4e {
    return pml4t;
}

inline fn tableFromIndex(comptime lvl: Level, pidx: Index) switch (lvl) {
    .pml4 => []Pml4e,
    .pdpt => []Pdpte,
    .pd => []Pde,
    .pt => []Pte,
} {
    switch (lvl) {
        .pml4 => {
            return lvl4Table();
        },
        .pdpt => {
            return tableFromIndex(.pml4, pidx)[pidx.pml4_idx].retrieve_table();
        },
        .pd => {
            return tableFromIndex(.pdpt, pidx)[pidx.pdpt_idx].retrieve_table();
        },
        .pt => {
            return tableFromIndex(.pd, pidx)[pidx.pd_idx].retrieve_table();
        },
    }
}

//fn tableFromVaddr(EntryType: type, comptime lvl: Level, vaddr: usize) []EntryType {
fn tableFromVaddr(comptime lvl: Level, vaddr: usize) switch (lvl) {
    .pml4 => []Pml4e,
    .pdpt => []Pdpte,
    .pd => []Pde,
    .pt => []Pte,
} {
    const pidx = indexFromVaddr(vaddr);
    return tableFromIndex(lvl, pidx);
}

fn retrieveEntryFromVaddr(EntryType: type, comptime pm: PagingMode, comptime ps: u32, comptime lvl: Level, vaddr: usize) *EntryType {
    const pidx = indexFromVaddr(vaddr);
    //const table = tableFromVaddr(EntryType, lvl, vaddr);
    const table: []EntryType = tableFromVaddr(lvl, vaddr);
    return switch (pm) {
        .four_level => switch (ps) {
            page_size_4k => switch (lvl) {
                .pml4 => &table[pidx.pml4_idx],
                .pdpt => &table[pidx.pdpt_idx],
                .pd => &table[pidx.pd_idx],
                .pt => &table[pidx.pt_idx],
            },
            page_size_2m => switch (lvl) {
                .pml4 => &table[pidx.pml4_idx],
                .pdpt => &table[pidx.pdpt_idx],
                .pd => &table[pidx.pd_idx],
                else => @compileError("Unsupported page level for 2-MByte page."),
            },
            page_size_1g => switch (lvl) { // Poprawiona wartość rozmiaru strony na format heksadecymalny
                .pml4 => &table[pidx.pml4_idx],
                .pdpt => &table[pidx.pdpt_idx],
                else => @compileError("Unsupported page level for 1-GByte page."),
            },
            else => @compileError("Unsupported page size"),
        },
        else => @compileError("Unsupported 5-Level Paging mode"),
    };
}

inline fn entryFromVaddr(comptime lvl: Level, vaddr: usize) *PagingStructureEntry(page_size, lvl) {
    return retrieveEntryFromVaddr(PagingStructureEntry(page_size, lvl), .four_level, page_size, lvl, vaddr);
}

/// Get virtual address from paging indexes using Higher Half Direct Mapping offset
pub inline fn vaddrFromPaddr(paddr: usize) usize {
    return paddr + hhdm_offset;
}

//const Pml4t = [512]Pml4e;
fn Pml4TableFromCr3() struct { []Pml4e, Cr3Structure(false) } {
    const cr3_formatted: Cr3Structure(false) = @bitCast(cpu.cr3());
    return .{ cr3_formatted.retrieve_table(Pml4), cr3_formatted };
}

var pml4t: []Pml4e = undefined;

pub fn print_tlb() void {
    for (pml4t, 0..) |e, i| {
        if (e.present) {
            log.err("tlb_pml4[{d:0>3}]@{*}: 0x{x} -> {*} of {}", .{ i, &e, e.aligned_address_4kbytes, e.retrieve_table(), e });
             for (e.retrieve_table()) |pdpte| {
                 if (pdpte.present) {
                     log.err("pdpte: {}", .{ pdpte  });
                     for (pdpte.retrieve_table()) |pde| {
                         if (pde.present) {
                             log.err("pde: {}", .{ pde });
            //                 for (pde.retrieve_table()) |pte| {
            //                     if (pte.present) {
            //                         log.warn("pte: 0x{x} -> {*}", .{ pte.aligned_address_4kbytes, pte.retrieve_frame_address() });
            //                     }
            //                 }
                         }
                     }
                 }
             }
        }
    }
}

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

    pml4t, const cr3_formatted = Pml4TableFromCr3();

    //const lvl4e = retrieveEntryFromVaddr(PagingStructureEntry(page_size, .lvl4), .four_level, page_size, .lvl4, 0xffff_8000_fe80_0000);
    log.warn("cr3 -> 0x{x}", .{cpu.cr3()});
    log.warn("pml4 ptr -> {*}", .{pml4t.ptr});
    const vaddr_test = 0xffff_8000_fe80_0000;
    const pidx = indexFromVaddr(vaddr_test);
    log.warn("pidx: -> {}", .{pidx});
    const pml4e = entryFromVaddr(.pml4, vaddr_test);
    log.warn("pml4e: -> {}, ptr={*}", .{ pml4e.*, pml4e });
    const pdpte = entryFromVaddr(.pdpt, vaddr_test);
    log.warn("pdpte:  -> {}", .{pdpte.*});
    const pde = entryFromVaddr(.pd, vaddr_test);
    log.warn("pde:  -> {}, pfn={*}", .{ pde.*, pde.retrieve_table() });
    const pte = entryFromVaddr(.pt, vaddr_test);
    log.warn("pte: -> {}, pfn= {*}", .{ pte.*, pte.retrieve_frame_address() });

    const pidx511: Index = .{ .pml4_idx = 511, .pdpt_idx = 511, .pd_idx = 0, .pt_idx = 0, .offset = 0 };
    //const vaddr511 = 0xffff_ffff_ffff_f000;
    const vaddr511 = vaddrFromIndex(pidx511);
    //const pidx511 = pagingIndexFromVaddr(vaddr511);
    log.warn("pidx511 -> {}", .{pidx511});
    const pml4e511 = entryFromVaddr(.pml4, vaddr511);
    log.warn("pml4e511: -> {}, vaddr=0x{x}, ptr={*}, ptr.table={*}, aligned_addres=0x{x}", .{ pml4e511.*, vaddr511, pml4e511, pml4e511.retrieve_table(), pml4e511.aligned_address_4kbytes });

    // const pidx510: Index = .{ .pml4_idx = 510, .pdpt_idx = 510, .pd_idx = 510, .pt_idx = 510, .offset = 0 };
    // const vaddr510 = vaddrFromIndex(pidx510);
    // log.warn("pidx510 -> {}", .{pidx510});
    // const pml4e510 = entryFromVaddr(.pml4, vaddr510);
    // log.warn("pml4e510: -> {}, ptr={*}", .{ pml4e510.*, pml4e510 });

    log.warn("cr4: 0b{b:0>64}", .{@as(u64, cpu.cr4())});
    log.warn("cr3: 0b{b:0>64}", .{@as(u64, cpu.cr3())});

    log.warn("pt:     0xFFFFFF00_00000000->0xFFFFFF7F_FFFFFFFF: {}->{}, diff: 0x{x}", .{ indexFromVaddr(0xFFFFFF00_00000000), indexFromVaddr(0xFFFFFF7F_FFFFFFFF), (0xFFFFFF7F_FFFFFFFF - 0xFFFFFF00_00000000) });
    const x = indexFromVaddr(0xFFFFFF7F_8000000);
    _ = &x;
    log.warn("\n\npd:    0xFFFF_FF7F8_000_0000->0xFFFFFF7F_BFFFFFFF : {}->{}, diff: 0x{x}", .{ indexFromVaddr(0xffff_ff7f_8000_0000), indexFromVaddr(0xFFFFFF7F_BFFFFFFF), (0xFFFFFF7F_BFFFFFFF - 0xFFFFFF7F_8000000) });
    log.warn("pdpt: 0xFFFFFF7F_BFC00000->0xFFFFFF7F_BFDFFFFF  : {}->{}, diff: 0x{x}", .{ indexFromVaddr(0xFFFFFF7F_BFC00000), indexFromVaddr(0xFFFFFF7F_BFDFFFFF), (0xFFFFFF7F_BFDFFFFF - 0xFFFFFF7F_BFC00000) });
    log.warn("pml4: 0xFFFFFF7F_BFDFE000 ->0xFFFFFF7F_BFDFEFFF   : {}->{}, diff:0x{x}", .{ indexFromVaddr(0xFFFFFF7F_BFDFE000), indexFromVaddr(0xFFFFFF7F_BFDFEFFF), (0xFFFFFF7F_BFDFEFFF - 0xFFFFFF7F_BFDFE000) });
    log.warn("pml4: 0xFFFFFF7F_BFDFE000 ->0xFFFFFF7F_BFDFEFFF   : {}->{}, diff:0x{x}", .{ indexFromVaddr(0xFFFFFF7F_BFDFE000), indexFromVaddr(0xFFFFFF7F_BFDFEFFF), (0xFFFFFF7F_BFDFEFFF - 0xFFFFFF7F_BFDFE000) });

    log.warn("\n\nkernel: {}->{}", .{ indexFromVaddr(0xffffff7f80000000), indexFromVaddr(0xffffff7f8009cb88) });

    const vmm_pml4 = tableFromVaddr(.pml4, 0xFFFFFF7F_BFDFE000);
    log.warn("vmm_pml4: 0xFFFFFF7F_BFDFE000 : {*}, len={d}, [0]={}@{*}, [511]={}@{*}", .{ vmm_pml4.ptr, vmm_pml4.len, vmm_pml4[0], &vmm_pml4[0], vmm_pml4[511], &vmm_pml4[511] });

    const vmm_pml4_2 = tableFromVaddr(.pml4, 0xFFFFFF7F_BFDFFFFF);
    log.warn("vmm_pml4_2: 0xFFFFFF7F_BFDFE008 : {*}, len={d}, [0]={}@{*}, [511]={}@{*}", .{ vmm_pml4_2.ptr, vmm_pml4_2.len, vmm_pml4_2[0], &vmm_pml4_2[0], vmm_pml4_2[511], &vmm_pml4_2[511] });

    const vmm_pdpt = tableFromVaddr(.pdpt, 0xFFFFFF7F_BFC00000);
    log.warn("vmm_pdpt: 0xFFFFFF7F_BFC00000 : {*}, len={d}, [0]={}@{*}, [511]={}@{*}", .{ vmm_pdpt.ptr, vmm_pdpt.len, vmm_pdpt[0], &vmm_pdpt[0], vmm_pdpt[511], &vmm_pdpt[511] });

    // recursive in 510, not 511 cause limine occupies it
    log.warn("cr3_formatted: {0}, {0b:0>40}, 0x{0x}", .{cr3_formatted.aligned_address_4kbytes});
    pml4t[510] = .{ .present = true, .writable = true, .aligned_address_4kbytes = @truncate(cr3_formatted.aligned_address_4kbytes) }; //we ignore the last bit
    cpu.invlpg(@intFromPtr(&pml4t[510]));
    log.err("&pml4[510]={*}", .{&pml4t[510]});

    // Dla PDPT
    // const pdpt_pidx = .{ .pml4_idx = 510, .pdpt_idx = 511, .pd_idx = 0, .pt_idx = 0, .offset = 0 };
    //  const pdpt511 = entryFromVaddr(.pdpt, vaddrFromIndex(pdpt_pidx));
    //  pdpt511.* = .{ .present = true, .writable = true, .aligned_address_4kbytes = @truncate(cr3_formatted.aligned_address_4kbytes) };

    // Dla PD
    // const pd_pidx = .{ .pml4_idx = 510, .pdpt_idx = 511, .pd_idx = 511, .pt_idx = 0, .offset = 0 };
    // const pd511 = entryFromVaddr(.pd, vaddrFromIndex(pd_pidx));
    // pd511.* = .{ .present = true, .writable = true, .aligned_address_4kbytes = @truncate(pdpt511.aligned_address_4kbytes) };

    // Dla PT
    // const pt_pidx = .{ .pml4_idx = 510, .pdpt_idx = 511, .pd_idx = 511, .pt_idx = 511, .offset = 0 };
    // const pt511 = entryFromVaddr(.pt, vaddrFromIndex(pt_pidx));
    // pt511.* = .{ .present = true, .writable = true, .aligned_address_4kbytes = @truncate(pd511.aligned_address_4kbytes) };


    // const pidx510: Index = .{ .pml4_idx = 510, .pdpt_idx = 0, .pd_idx = 0, .pt_idx = 0 , .offset = 0 };
    // const vaddr510 = vaddrFromIndex(pidx510);
    // log.warn("pidx510 -> {}", .{pidx510});
    // const pml4e510 = entryFromVaddr(.pml4, vaddr510);
    // log.warn("pml4e510: -> {}, ptr={*}", .{ pml4e510.*, pml4e510 });


    //print_tlb();

    // const tphys = physFromVirt(0xFFFFFF7F_8000000);
    // log.warn("tphys: 0x{x}", .{tphys});

}
