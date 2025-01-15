//! This is paging solely for 4-Level Paging, but it also supports 4-Kilobyte, 2-Megabyte, and 1-Gigabyte pages.
//! For now this code supports both recursive page table mapping and CR3-based page table mapping.
//! For recursive mapping, it uses 510 (not 511) in the PML4 table.
//! Virtual Address for Address Structure (octal)
//! Page 0o_SSSSSS_AAA_BBB_CCC_DDD_EEEE
//! Level 1 Table Entry PML4 0o_SSSSSS_RRR_AAA_BBB_CCC_DDDD
//! Level 2 Table Entry PDPT 0o_SSSSSS_RRR_RRR_AAA_BBB_CCCC
//! Level 3 Table Entry PD   0o_SSSSSS_RRR_RRR_RRR_AAA_BBBB
//! Level 4 Table Entry PT   0o_SSSSSS_RRR_RRR_RRR_RRR_AAAA,
//! where: SSSSSS is the sign extension of the 48-bit address
//! RRR is the index of the recursive entry, which means that they are all copies of bit 47
//! AAA is the index into the PML4 (lvl4) table
//! BBB is the index into the PDPT (lvl3) table
//! CCC is the index into the PD (lvl2) table
//! DDD is the index into the PT (lvl1) table
//! EEEE is the offset into the page

const limine = @import("limine");
const std = @import("std");
const cpu = @import("cpu.zig");
const config = @import("config");

const log = std.log.scoped(.paging);
const assert = std.debug.assert;

pub const PATType = enum(u8) {
    uncacheable = 0x00, //UC
    write_combining = 0x01, //WC
    write_through = 0x04, //WT
    write_protected = 0x05, //WP
    write_back = 0x06, //WB
    uncached = 0x07, //(UC-)
};

const PAT = struct {
    const Self = @This();

    pat: [8]PATType = .{ PATType.write_back, PATType.write_through, PATType.uncached, PATType.uncacheable, PATType.write_back, PATType.write_through, PATType.uncached, PATType.uncacheable },

    fn set(self: *Self, idx: u3, pt: PATType) void {
        assert(idx < 8, "Invalid PAT index");
        self.pat[idx] = pt;
    }

    // read MSR and mutate the state of the struct
    fn read(self: *Self) void {
        const val = cpu.rdmsr(0x277);
        var i: u4 = 0; //we need u3 but we need to iterate 8 times (0,1,2,...7 and 8)
        while (i < 8) : (i += 1) {
            const pt: PATType = @enumFromInt(@as(u8, @truncate(val >> @as(u6, i) * 8)));
            log.debug("PAT[{d}] : {}", .{ i, pt });
            self.pat[i] = pt;
        }
    }

    fn write(self: Self) void {
        cpu.wrmsr(0x277, @bitCast(self.pat));
    }

    fn patFromPageFlags(self: Self, page_pat: u1, page_pcd: bool, page_pwt: bool) PATType {
        const pat_idx = @as(u3, @as(u3, page_pat) << 2 | @as(u2, @intFromBool(page_pcd)) << 1 | @intFromBool(page_pwt));
        return self.pat[pat_idx];
    }

    fn pageFlagsFromPat(self: Self, req_pat: PATType) struct { page_pat: u1, page_pcd: bool, page_pwt: bool } {
        var pat_idx: ?u3 = null;
        for (self.pat, 0..) |pt, idx| {
            if (pt == req_pat) {
                pat_idx = @intCast(idx);
                break;
            }
        }
        if (pat_idx) |pi| {
            return .{ .page_pat = @truncate(pi >> 2), .page_pcd = (pi & 0b010) >> 1 == 1, .page_pwt = pi & 0b001 == 1 };
        } 
        
        @panic("PAT type not found");
    }
};

fn retrievePagePAT(page_entry_info: GenericEntryInfo) PATType {
    switch (page_entry_info.ps) {
        inline else => |ps| {
            const entry: *PageEntry(ps) = @ptrCast(page_entry_info.entry_ptr);
            return pat.patFromPageFlags(entry.pat, entry.cache_disabled, entry.write_through);
        },
    }
}

fn setPagePAT(page_entry_info: GenericEntryInfo, req_pat: PATType) void {
    const page_req_pat_flags = pat.pageFlagsFromPat(req_pat);
    switch (page_entry_info.ps) {
        inline else => |ps| {
            const entry: *PageEntry(ps) = @ptrCast(page_entry_info.entry_ptr);
            entry.pat = page_req_pat_flags.page_pat;
            entry.cache_disabled = page_req_pat_flags.page_pcd;
            entry.write_through = page_req_pat_flags.page_pwt;
        },
    }
}

fn adjustPagePAT(virt: usize, page_entry_info: GenericEntryInfo, req_pat: PATType) void {
    log.debug("Adjusting Page PAT: {any}", .{page_entry_info});
    if (page_entry_info.entry_ptr == null) {
        @panic("NVMe BAR is not mapped");
    }

    const current_page_pat = retrievePagePAT(page_entry_info);

    if (current_page_pat != req_pat) {
        log.warn("Adjusting NVMe BAR Page Attributes: current {} -> {}", .{ current_page_pat, req_pat });

        setPagePAT(page_entry_info, req_pat);
        // page entries indicates frames so we need to flush them, as Intel Programmer's Guidesays
        // "If software modifies a paging-structure entry that maps a page (rather than referencing another paging
        // structure), it should execute INVLPG for any linear address with a page number whose translation uses that
        // paging-structure entry."
        flushTLB(virt);
    }
}

/// Set a new PAT type for the given virtual address and size (one or more pages)
/// @param virt: Virtual address
/// @param sz: Size in bytes of the area to adjust
/// @param req_pat: Requested PAT type
pub fn adjustPageAreaPAT(virt: usize, sz: usize, req_pat: PATType) !void {
    if (sz == 0) return;
    const pg_entry_info = try recLowestEntryFromVirtInfo(virt);
    const pg_sz = @intFromEnum(pg_entry_info.ps);
    const pg_mask: usize = pg_sz - 1;

    // Remaing size to adjust, it's a multiple of page size
    var rem_sz = if (sz % pg_sz != 0) (sz + pg_mask) & ~pg_mask else sz;
    var cur_virt = virt;

    while (rem_sz > 0) : (rem_sz -= pg_sz) {
        adjustPagePAT(virt, pg_entry_info, req_pat);
        cur_virt += pg_sz;
    }
}

fn flushTLB(virt: usize) void {
    cpu.invlpg(virt);
}

fn RecursiveInfo(comptime recursive_index: u9) type {
    return struct {
        const rec_idx: usize = recursive_index; //510
        const sign = 0o177777 << 48; //sign extension

        // retrieve the page table indices of the address that we want to translate
        pub inline fn pml4TableAddr() usize {
            return sign | (rec_idx << 39) | (rec_idx << 30) | (rec_idx << 21) | (rec_idx << 12);
        }
        pub inline fn pdptTablAddr(pml4_idx: usize) usize {
            return sign | (rec_idx << 39) | (rec_idx << 30) | (rec_idx << 21) | (pml4_idx << 12);
        }
        pub inline fn pdTableAddr(pml4_idx: usize, pdpt_idx: usize) usize {
            return sign | (rec_idx << 39) | (rec_idx << 30) | (pml4_idx << 21) | (pdpt_idx << 12);
        }
        pub inline fn ptTableAddr(pml4_idx: usize, pdpt_idx: usize, pd_idx: usize) usize {
            return sign | (rec_idx << 39) | (pml4_idx << 30) | (pdpt_idx << 21) | (pd_idx << 12);
        }
    };
}

const PageSize = enum(u32) { ps4k = 0x1000, ps2m = 0x200000, ps1g = 0x40000000 };
pub const default_page_size: PageSize = @enumFromInt(config.mem_page_size);

const PagingMode = enum(u1) {
    four_level = 0,
    five_level = 1,
};

const GenericEntry = usize;
const RecInfo = RecursiveInfo(510); //0x776

pub const GenericEntryInfo = struct {
    entry_ptr: ?*GenericEntry,
    lvl: Level,
    ps: PageSize,
};

pub fn Cr3Structure(comptime pcid: bool) type {
    if (pcid) {
        return packed struct(GenericEntry) {
            const Self = @This();
            pcid: u12, //0-11
            aligned_address_4kbytes: u40, //12-51- PMPL4|PML5 address
            rsrvd: u12 = 0, //52-63

            pub fn retrieve_table(self: Self, T: type) *T {
                return @ptrFromInt(virtFromMME(self.aligned_address_4kbytes << @bitSizeOf(u12)));
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
                return @ptrFromInt(virtFromMME(self.aligned_address_4kbytes << @bitSizeOf(u12)));
            }
        };
    }
}

pub const Pml4e = PagingStructureEntry(default_page_size, .pml4);
pub const Pdpte = PagingStructureEntry(default_page_size, .pdpt);
pub const Pdpte1Gbyte = PagingStructureEntry(.ps1g, .pdpt);
pub const Pde = PagingStructureEntry(default_page_size, .pd);
pub const Pde2MByte = PagingStructureEntry(.ps2m, .pd);
pub const Pte = PagingStructureEntry(default_page_size, .pt);
pub const Pml4 = [512]Pml4e;
pub const Pdpt = [512]Pdpte;
pub const Pd = [512]Pde;
pub const Pt = [512]Pte;

// the lowest level entry stoing the frame address
fn PageEntry(comptime ps: PageSize) type {
    return switch (ps) {
        .ps4k => Pte,
        .ps2m => Pde2MByte,
        .ps1g => Pdpte1Gbyte,
    };
}

// TODO: usngnamespace does not work in case of the fields
pub fn PagingStructureEntry(comptime ps: PageSize, comptime lvl: Level) type {
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

            pub fn retrieveTable(self: Self) ?[]Pdpte {
                return if (self.present) @as(*Pdpt, @ptrFromInt(virtFromMME(self.aligned_address_4kbytes << @bitSizeOf(u12)))) else null;
            }
        },
        // .pdpte1gbytes
        .pdpt => switch (ps) {
            .ps1g => packed struct(GenericEntry) {
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
                aligned_address_1gbytes: u21, //30-50
                rsrvd_b: u1, //51 //must be 0
                ignrd_b: u7, //52-58
                protection_key: u4, //59-62
                execute_disable: bool, //63

                pub inline fn retrieveFrameVirt(self: Self) ?usize {
                    return if (self.present) self.aligned_address_1gbytes else null;
                }

                pub inline fn retrieveFrame(self: Self) ?[]usize {
                    return if (self.present) @as(*[.ps1g]GenericEntry, @ptrFromInt(self.retrieveFrameVirt().?)) else null;
                }
            },
            .ps4k, .ps2m => packed struct(GenericEntry) {
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

                pub inline fn retrieveTable(self: Self) ?[]Pde {
                    return if (self.present) @as(*Pd, @ptrFromInt(virtFromMME(self.aligned_address_4kbytes << @bitSizeOf(u12)))) else null;
                }
            },
            //            else => @compileError("Unsupported page size:" ++ @tagName(ps)),
        },
        .pd => switch (ps) {
            .ps2m => packed struct(GenericEntry) {
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
                aligned_address_2mbytes: u30, //21-50
                rsrvd_b: u1 = 0, //51
                ignrd_b: u7 = 0, //52-58
                protection_key: u4 = 0, //59-62
                execute_disable: bool = false, //63

                pub inline fn retrieveFrameVirt(self: Self) ?usize {
                    return if (self.present) self.aligned_address_2mbytes else null;
                }

                pub inline fn retrievFrame(self: Self) ?[]usize {
                    return if (self.present) @as(*[.ps2m]usize, @ptrFromInt(self.retrieveFrameVirt().?)) else null;
                }
            },
            .ps4k => packed struct(GenericEntry) {
                const Self = @This();
                present: bool = false, //0
                writable: bool = false, //1
                user: bool = false, //2
                write_through: bool = false, //3
                cache_disabled: bool = false, //4
                accessed: bool = false, //5
                ignrd_a: bool = false, //6
                hudge: bool = false, //7 //must be 0
                ignrd_b: u3 = 0, //8-10
                restart: u1 = 0, //11
                aligned_address_4kbytes: u39, //12-50
                rsrvd_a: u1 = 0, //51-51 //must be 0
                ignrd_c: u11 = 0, //52-62
                execute_disable: bool = true, //63
                pub inline fn retrieveTable(self: Self) ?[]Pte {
                    return if (self.present) @as(*Pt, @ptrFromInt(virtFromMME(self.aligned_address_4kbytes << @bitSizeOf(u12)))) else null;
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

            pub inline fn retrieveFrameVirt(self: Self) ?usize {
                return if (self.present) self.aligned_address_4kbytes else null;
            }

            pub inline fn retrieveFrame(self: Self) ?[]usize {
                return if (self.present) @as(*[@intFromEnum(PageSize.ps4k)]GenericEntry, @ptrFromInt(self.retrieveFrameVirt().?)) else null;
            }
        },
    };
}

/// Holds indexes of all paging tables
/// each table holds indexes of 512 entries, so we need only 9 bytes to store index
/// Offset is 12 bits to address 4KiB page
const Index = struct {
    const Self = @This();
    pml4_idx: u9, //pml4
    pdpt_idx: u9, //pdpt
    pd_idx_or_high_offset: u9, //pd
    pt_idx_or_high_offset: u9, //pt
    //offset: u12,
    offset: u12, //12 bites for 4k pages, 21 for 2m pages, 30 for 1g pages

    pub fn yieldOffset(self: Self, comptime page_size: PageSize) switch (page_size) {
        .ps4k => u12,
        .ps2m => u21,
        .ps1g => u30,
    } {
        return switch (page_size) {
            .ps4k => self.offset,
            .ps2m => (@as(u21, self.pt_idx_or_high_offset) << 12) + self.offset,
            .ps1g => (@as(u30, self.pd_idx_or_high_offset) << 21) + (@as(u21, self.pt_idx_or_high_offset) << 12) + self.offset,
        };
    }
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

/// Get paging indexes from virtual address
/// It maps 48-bit virtual address to 9-bit indexes of all 52 physical address bits
/// src osdev: "Virtual addresses in 64-bit mode must be canonical, that is,
/// the upper bits of the address must either be all 0s or all 1s.
// For systems supporting 48-bit virtual address spaces, the upper 16 bits must be the same"
pub inline fn indexFromVaddr(virt: usize) Index {
    return .{
        .pml4_idx = @truncate(virt >> 39), //47->39
        .pdpt_idx = @truncate(virt >> 30), //39->30
        .pd_idx_or_high_offset = @truncate(virt >> 21), //30->21
        .pt_idx_or_high_offset = @truncate(virt >> 12), //21->12
        .offset = @truncate(virt), //12 bites
    };
}

// test indexFromVaddr {
//     try std.testing.expect(Index{ .lvl4 = 0, .lvl3 = 0, .lvl2 = 0, .pt = 2, .offset = 1 }, indexFromVaddr(0x2001));
// }

// Get virtual address from paging indexes
pub inline fn virtFromIndex(pidx: Index) usize {
    const addr = (@as(usize, pidx.pml4_idx) << 39) | (@as(usize, pidx.pdpt_idx) << 30) | (@as(usize, pidx.pd_idx_or_high_offset) << 21) | @as(usize, pidx.pt_idx_or_high_offset) << 12 | pidx.offset;
    switch (addr & @as(usize, 1) << 47) {
        0 => return addr & 0x7FFF_FFFF_FFFF,
        @as(usize, 1) << 47 => return addr | 0xFFFF_8000_0000_0000,
        else => @panic("Invalid address"),
    }
}

// test virtFromIndex {
//     try std.testing.expect(0x2001, virtFromIndex(.{ .lvl4 = 0, .lvl3 = 0, .lvl2 = 0, .lvl1 = 2, .offset = 1 }));
//     try std.testing.expect(0xffff800000100000, virtFromIndex(.{ .lvl4 = 0x100, .lvl3 = 0x0, .lvl2 = 0x0, .lvl1 = 0x100, .offset = 0x0 }));
// }

pub fn physFromVirtInfo(virt: usize) !struct { phys: usize, lvl: Level, ps: PageSize } {
    const pidx = indexFromVaddr(virt);
    log.debug("pidx: {any}", .{pidx});

    const pml4_table: ?[]Pml4e = tableFromIndex(.pml4, pidx) orelse return error.PageFault;
    const pdpt_table: ?[]Pdpte = pml4_table.?[pidx.pml4_idx].retrieveTable() orelse return error.PageFault;

    const pdpte = pdpt_table.?[pidx.pdpt_idx];
    if (!pdpte.present) return error.PageFault;

    if (pdpte.hudge) {
        return .{ .phys = (@as(PagingStructureEntry(.ps1g, .pdpt), @bitCast(pdpte)).retrieveFrameVirt().? << @bitSizeOf(u30)) + pidx.yieldOffset(.ps1g), .lvl = .pdpt, .ps = .ps1g };
    }

    const pd_table: ?[]Pde = pdpte.retrieveTable() orelse return error.PageFault;
    const pde = pd_table.?[pidx.pd_idx_or_high_offset];
    if (!pde.present) return error.PageFault;

    if (pde.hudge) {
        return .{ .phys = (@as(PagingStructureEntry(.ps2m, .pd), @bitCast(pde)).retrieveFrameVirt().? << @bitSizeOf(u21)) + pidx.yieldOffset(.ps2m), .lvl = .pd, .ps = .ps2m };
    }

    const pt_table: ?[]Pte = pde.retrieveTable() orelse return error.PageFault;
    const pte = pt_table.?[pidx.pt_idx_or_high_offset];
    if (!pte.present) return error.PageFault;

    return .{ .phys = (@as(PagingStructureEntry(.ps4k, .pt), pte).retrieveFrameVirt().? << @bitSizeOf(u12)) + pidx.yieldOffset(.ps4k), .lvl = .pt, .ps = .ps4k };
}

// Recursive get physical address from virtual address
pub fn recPhysFromVirtInfo(virt: usize) !struct { phys: usize, lvl: Level, ps: PageSize } {
    const pidx = indexFromVaddr(virt);

    // check if pml4 entry is present
    const pml4e = @as(*Pml4, @ptrFromInt(RecInfo.pml4TableAddr()))[pidx.pml4_idx];
    if (!pml4e.present) return error.PageFault;

    // check if pdpt entry is present
    const pdpte = @as(*Pdpt, @ptrFromInt(RecInfo.pdptTablAddr(pidx.pml4_idx)))[pidx.pdpt_idx];
    if (!pdpte.present) return error.PageFault;

    if (pdpte.hudge) {
        return .{ .phys = (@as(PagingStructureEntry(.ps1g, .pdpt), @bitCast(pdpte)).retrieveFrameVirt().? << @bitSizeOf(u30)) + pidx.yieldOffset(.ps1g), .lvl = .pdpt, .ps = .ps1g };
    }

    // check if pd entry is present
    const pde = @as(*Pd, @ptrFromInt(RecInfo.pdTableAddr(pidx.pml4_idx, pidx.pdpt_idx)))[pidx.pd_idx_or_high_offset];
    if (!pde.present) return error.PageFault;

    if (pde.hudge) {
        return .{ .phys = (@as(PagingStructureEntry(.ps2m, .pd), @bitCast(pde)).retrieveFrameVirt().? << @bitSizeOf(u21)) + pidx.yieldOffset(.ps2m), .lvl = .pd, .ps = .ps2m };
    }

    // check if pt entry is present
    const pte = @as(*Pt, @ptrFromInt(RecInfo.ptTableAddr(pidx.pml4_idx, pidx.pdpt_idx, pidx.pd_idx_or_high_offset)))[pidx.pt_idx_or_high_offset];
    if (!pte.present) return error.PageFault;

    return .{ .phys = (@as(PagingStructureEntry(.ps4k, .pt), pte).retrieveFrameVirt().? << @bitSizeOf(u12)) + pidx.yieldOffset(.ps4k), .lvl = .pt, .ps = .ps4k };
}

pub inline fn physFromVirt(virt: usize) !usize {
    const info = try physFromVirtInfo(virt);
    return info.phys;
}

pub inline fn recPhysFromVirt(virt: usize) !usize {
    const info = try recPhysFromVirtInfo(virt);
    return info.phys;
}

inline fn lvl4Table() []Pml4e {
    return pml4t;
}

inline fn tableFromIndex(comptime lvl: Level, pidx: Index) switch (lvl) {
    .pml4 => ?[]Pml4e,
    .pdpt => ?[]Pdpte,
    .pd => ?[]Pde,
    .pt => ?[]Pte,
} {
    switch (lvl) {
        .pml4 => {
            return lvl4Table();
        },
        .pdpt => {
            return tableFromIndex(.pml4, pidx).?[pidx.pml4_idx].retrieveTable();
        },
        .pd => {
            return tableFromIndex(.pdpt, pidx).?[pidx.pdpt_idx].retrieveTable();
        },
        .pt => {
            return tableFromIndex(.pd, pidx).?[pidx.pd_idx_or_high_offset].retrieveTable();
        },
    }
}

//fn tableFromVaddr(EntryType: type, comptime lvl: Level, vaddr: usize) []EntryType {
fn tableFromVaddr(comptime lvl: Level, virt: usize) switch (lvl) {
    .pml4 => ?[]Pml4e,
    .pdpt => ?[]Pdpte,
    .pd => ?[]Pde,
    .pt => ?[]Pte,
} {
    const pidx = indexFromVaddr(virt);
    return tableFromIndex(lvl, pidx);
}

// Search for the lowest level entry in the paging table which is present
pub fn lowestEntryFromVirtInfo(virt: usize) !GenericEntryInfo {
    const pidx = indexFromVaddr(virt);

    var res: GenericEntryInfo = .{ .entry_ptr = null, .lvl = .pt, .ps = .ps4k };
    inline for ([_]Level{ Level.pml4, Level.pdpt, Level.pd, Level.pt }) |lvl_idx| {
        const table = tableFromIndex(lvl_idx, pidx) orelse return error.PageFault;

        switch (lvl_idx) {
            .pml4 => {
                const entry_ptr = &table[pidx.pml4_idx];
                if (!entry_ptr.present) {
                    return error.PageFault;
                }
                res = .{ .entry_ptr = @ptrCast(entry_ptr), .lvl = lvl_idx, .ps = .ps4k };
            },
            .pdpt => {
                const entry_ptr = &table[pidx.pdpt_idx];
                if (!entry_ptr.present) {
                    return res;
                }

                if (entry_ptr.hudge) {
                    return .{ .entry_ptr = @ptrCast(entry_ptr), .lvl = lvl_idx, .ps = .ps1g };
                }

                res = .{ .entry_ptr = @ptrCast(entry_ptr), .lvl = lvl_idx, .ps = .ps2m };
            },
            .pd => {
                const entry_ptr = &table[pidx.pd_idx_or_high_offset];
                if (!entry_ptr.present) {
                    return res;
                }

                if (entry_ptr.hudge) {
                    return .{ .entry_ptr = @ptrCast(entry_ptr), .lvl = lvl_idx, .ps = .ps2m };
                }

                res = .{ .entry_ptr = @ptrCast(entry_ptr), .lvl = lvl_idx, .ps = .ps4k };
            },
            .pt => {
                const entry_ptr = &table[pidx.pt_idx_or_high_offset];
                if (!entry_ptr.present) {
                    return res;
                }

                return .{ .entry_ptr = @ptrCast(entry_ptr), .lvl = lvl_idx, .ps = .ps4k };
            },
        }
    }
}

pub fn recLowestEntryFromVirtInfo(virt: usize) !GenericEntryInfo {
    const pidx = indexFromVaddr(virt);

    var res: GenericEntryInfo = .{ .entry_ptr = null, .lvl = .pml4, .ps = .ps4k };

    // check if pml4 entry is present
    const pml4e = &@as(*Pml4, @ptrFromInt(RecInfo.pml4TableAddr()))[pidx.pml4_idx];
    if (!pml4e.present) return error.PageFault;

    res = .{ .entry_ptr = @ptrCast(pml4e), .lvl = .pml4, .ps = .ps4k };

    // check if pdpt entry is present
    const pdpte = &@as(*Pdpt, @ptrFromInt(RecInfo.pdptTablAddr(pidx.pml4_idx)))[pidx.pdpt_idx];

    if (!pdpte.present) return res;

    if (pdpte.hudge) {
        return .{ .entry_ptr = @ptrCast(pdpte), .lvl = .pdpt, .ps = .ps1g };
    }

    res = .{ .entry_ptr = @ptrCast(pdpte), .lvl = .pdpt, .ps = .ps2m };

    const pde = &@as(*Pd, @ptrFromInt(RecInfo.pdTableAddr(pidx.pml4_idx, pidx.pdpt_idx)))[pidx.pd_idx_or_high_offset];
    if (!pde.present) return res;

    if (pde.hudge) {
        return .{ .entry_ptr = @ptrCast(pde), .lvl = .pd, .ps = .ps2m };
    }

    const pte = &@as(*Pt, @ptrFromInt(RecInfo.ptTableAddr(pidx.pml4_idx, pidx.pdpt_idx, pidx.pd_idx_or_high_offset)))[pidx.pt_idx_or_high_offset];
    if (!pte.present) return res;

    return .{ .entry_ptr = @ptrCast(pte), .lvl = .pt, .ps = .ps4k };
}

/// Get virtual address from paging indexes using Higher Half Direct Mapping offset
pub inline fn virtFromMME(paddr: usize) usize {
    return paddr + hhdm_offset;
}

fn Pml4TableFromCr3() struct { []Pml4e, Cr3Structure(false) } {
    const cr3_formatted: Cr3Structure(false) = @bitCast(cpu.cr3());
    return .{ cr3_formatted.retrieve_table(Pml4), cr3_formatted };
}

pub fn debugLowestEntryFromVirt(virt: usize) void {
    const page_entry_info = recLowestEntryFromVirtInfo(virt) catch @panic("Failed to get page entry info for NVMe BAR");
    log.debug("page entry info: {} ", .{page_entry_info});

    if (page_entry_info.entry_ptr == null) {
        log.err("Entry not found for virt: 0x{x}", .{virt});
        return;
    }
    switch (page_entry_info.ps) {
        .ps1g => {
            const entry: *Pdpte1Gbyte = @ptrCast(page_entry_info.entry_ptr);
            log.debug(".ps1g entry: {any}", .{entry});
        },
        .ps2m => {
            const entry: *Pde2MByte = @ptrCast(page_entry_info.entry_ptr);
            log.debug(".ps2m entry: {any}", .{entry});
        },
        .ps4k => {
            const entry: *Pte = @ptrCast(page_entry_info.entry_ptr);
            log.debug(".ps4k entry: {any}", .{entry});
        },
    }
}

var pml4t: []Pml4e = undefined;
var pat: PAT = undefined;

// pub fn print_tlb() void {
//     for (pml4t, 0..) |e, i| {
//         if (e.present) {
//             log.err("tlb_pml4[{d:0>3}]@{*}: 0x{x} -> {any} of {}", .{ i, &e, e.aligned_address_4kbytes, e.retrieveTable(), e });
//             for (e.retrieveTable().?) |pdpte| {
//                 if (pdpte.present) {
//                     log.err("pdpte: {}", .{pdpte});
//                     for (pdpte.retrieveTable().?) |pde| {
//                         if (pde.present) {
//                             log.err("pde: {}", .{pde});
//                             //                 for (pde.retrieve_table()) |pte| {
//                             //                     if (pte.present) {
//                             //                         log.warn("pte: 0x{x} -> {*}", .{ pte.aligned_address_4kbytes, pte.retrieve_frame_address() });
//                             //                     }
//                             //                 }
//                         }
//                     }
//                 }
//             }
//         }
//     }
// }
//

// Partially implemented for 4kbytes pages and 2mbytes pages; Does not iterate over page/frame entries
// TODO:implement it for 1gbytes and for all offsets inside a page
pub fn findPhys(phys: usize) void {
    for (pml4t, 0..) |e, lvl4_idx| {
        if (e.present) {
            //log.err("findPhys: tlb_pml4[{d:0>3}]@{*}: 0x{x} -> {any} of {}", .{ i, &e, e.aligned_address_4kbytes, e.retrieveTable(), e });
            for (e.retrieveTable().?, 0..) |pdpte, lvl3_idx| {
                if (pdpte.present) {
                    //log.err("findPhys: pdpte: {}", .{pdpte});
                    for (pdpte.retrieveTable().?, 0..) |pde, lvl2_idx| {
                        if (pde.present) {
                            //log.err("findPhys: pde: {}", .{pde});
                            if (pde.hudge) {
                                const pde_phys = (@as(PagingStructureEntry(.ps2m, .pd), @bitCast(pde)).retrieveFrameVirt().?) << @bitSizeOf(u21);
                                //log.err("findPhys: found pde huge: {}, phys: 0x{x}", .{ pde, phys });
                                if (pde_phys == phys) {
                                    log.err("findPhys: found pde huge: pml4t[{d}]={} pdpt[{d}]={}, pd[{d}]={}, phys=0x{x}", .{ lvl4_idx, e, lvl3_idx, pdpte, lvl2_idx, pde, phys });
                                    const virt = virtFromIndex(.{ .pml4_idx = @intCast(lvl4_idx), .pdpt_idx = @intCast(lvl3_idx), .pd_idx_or_high_offset = @intCast(lvl2_idx), .pt_idx_or_high_offset = 0, .offset = 0 });
                                    log.err("findPhys: virt: 0x{x}", .{virt});

                                    return;
                                }
                            } else {
                                for (pde.retrieveTable().?) |pte| {
                                    if (pte.present) {
                                        const pte_phys = (@as(PagingStructureEntry(.ps4k, .pt), pte).retrieveFrameVirt().?) << @bitSizeOf(u12);
                                        if (pte_phys == phys) {
                                            log.err("findPhys: found pte: {}, phys: 0x{x}", .{ pde, phys });
                                            return;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

pub fn init() !void {
    log.debug("Initializing...", .{});
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
                @panic("5-level paging not supported yet");
            },
        }
    } else @panic("No paging mode bootloader response available");

    // setup PAT
    pat = PAT{};
    pat.write(); //set default values
    pat.read(); //read values to be sure we set it right
    log.debug("The 0x277 MSR register value after the change: 0x{}", .{pat});

    pml4t, const cr3_formatted = Pml4TableFromCr3();
    log.debug("PML4 table: {*}, cr3_formated: {}", .{ pml4t.ptr, cr3_formatted });

    // Get ready for recursive paging
    pml4t[510] = .{ .present = true, .writable = true, .aligned_address_4kbytes = @truncate(cr3_formatted.aligned_address_4kbytes) };

    //const lvl4e = retrieveEntryFromVaddr(Pml4e, .four_level, default_page_size, .lvl4, 0xffff_8000_fe80_0000);
    log.warn("cr3 -> 0x{x}", .{cpu.cr3()});
    //log.warn("pml4 ptr -> {*}\n\n", .{pml4t.ptr});
    //
    //const vaddr_test = 0xffff_8000_fe80_0000;
    // const vaddr_test = 0xffff800040132000;
    // const pidx = indexFromVaddr(vaddr_test);
    // log.warn("pidx: 0x{x} -> {}", .{ vaddr_test, pidx });
    // const vaddr_test_info = try recLowestEntryFromVirtInfo(vaddr_test);
    // log.warn("pde:  0x{x} -> {any}", .{ vaddr_test, vaddr_test_info });
    // if (vaddr_test_info.entry_ptr == null) {
    //     log.err("Entry not found for vaddr: 0x{x}", .{vaddr_test});
    // }
    // const spec_entry: *Pde2MByte = @ptrCast(vaddr_test_info.entry_ptr);
    // log.warn("entry of {any}, val={!}\n\n", .{ @TypeOf(spec_entry), spec_entry });
    // const pte = entryFromVaddr(.pt, vaddr_test);
    // log.warn("pte: -> {any}, pfn= {*}\n\n", .{ pte.*, pte.retrieveFrame().?.ptr });
    //
    //
    // const phys_pci = try physFromVirtInfo(0xffff_8000_fe80_0000);
    // log.warn("phys_pci: 0x{any}", .{phys_pci});
    // log.warn("phys_pci_virt: 0x{x}", .{phys_pci.phys});
    //
    // const phys_buddy = try physFromVirtInfo(0xffff80001010a000);
    // log.warn("phys_buddy: 0x{any}", .{phys_buddy});
    // log.warn("phys_buddy_virt: 0x{x}", .{phys_buddy.phys});
    //
    // //wite loop to iterate over each element of address in the table
    const vt = [_]usize{ virtFromMME(0x4d00), virtFromMME(0x10_0000), virtFromMME(0x7fa61000), virtFromMME(0x7fa63000), virtFromMME(0xfee0_0000) };
    for (vt) |vaddr| {
        log.err("Virtual Adddress to check: 0x{x}", .{vaddr});

        // const vaddr_info = try recLowestEntryFromVirtInfo(vaddr);
        // log.err("Paging Table:  0x{x} -> {any}", .{ vaddr, vaddr_info });
        // const phys_by_rec = recPhysFromVirt(vaddr) catch |err| {
        //     log.err("Call function recPhysFromVirtvirt: 0x{x} -> error: {}", .{ vaddr, err });
        //     continue;
        // };
        const vaddr_info = try lowestEntryFromVirtInfo(vaddr);
        log.err("Paging Table:  0x{x} -> {any}", .{ vaddr, vaddr_info });
        const phys_rec = physFromVirt(vaddr) catch |err| {
            log.err("Call function physFromVirtvirt: 0x{x} -> error: {}", .{ vaddr, err });
            continue;
        };

        log.err("Call function phyFromVirt: vaddr: 0x{x} -> 0x{x}", .{ vaddr, phys_rec });
    }

    //   log.info("Find phys 0xfee0_0000", .{});
    //   findPhys(0xfee0_0000);

    //
    //
    //
    // // const pidx511: Index = .{ .pml4_idx = 511, .pdpt_idx = 511, .pd_idx = 0, .pt_idx = 0, .offset = 0 };
    // // //const vaddr511 = 0xffff_ffff_ffff_f000;
    // // const vaddr511 = vaddrFromIndex(pidx511);
    // // //const pidx511 = pagingIndexFromVaddr(vaddr511);
    // // log.warn("pidx511 -> {}", .{pidx511});
    // // const pml4e511 = entryFromVaddr(.pml4, vaddr511);
    // // log.warn("pml4e511: -> {}, vaddr=0x{x}, ptr={*}, ptr.table={*}, aligned_addres=0x{x}", .{ pml4e511.*, vaddr511, pml4e511, pml4e511.retrieveTable().?, pml4e511.aligned_address_4kbytes });
    // //
    // // const pidx510: Index = .{ .pml4_idx = 510, .pdpt_idx = 510, .pd_idx = 510, .pt_idx = 510, .offset = 0 };
    // // const vaddr510 = vaddrFromIndex(pidx510);
    // // log.warn("pidx510 -> {}", .{pidx510});
    // // const pml4e510 = entryFromVaddr(.pml4, vaddr510);
    // // log.warn("pml4e510: -> {}, ptr={*}", .{ pml4e510.*, pml4e510 });
    // //
    // // log.warn("cr4: 0b{b:0>64}", .{@as(u64, cpu.cr4())});
    // // log.warn("cr3: 0b{b:0>64}", .{@as(u64, cpu.cr3())});
    // //
    // // log.warn("pt:     0xFFFFFF00_00000000->0xFFFFFF7F_FFFFFFFF: {}->{}, diff: 0x{x}", .{ indexFromVaddr(0xFFFFFF00_00000000), indexFromVaddr(0xFFFFFF7F_FFFFFFFF), (0xFFFFFF7F_FFFFFFFF - 0xFFFFFF00_00000000) });
    // // const x = indexFromVaddr(0xFFFFFF7F_8000000);
    // // _ = &x;
    // // log.warn("\n\npt:    0xFFFF_FF7F8_000_0000->0xFFFFFF7F_BFFFFFFF : {}->{}, diff: 0x{x}", .{ indexFromVaddr(0xffff_ff7f_8000_0000), indexFromVaddr(0xFFFFFF7F_BFFFFFFF), (0xFFFFFF7F_BFFFFFFF - 0xFFFFFF7F_8000000) });
    // // log.warn("pdpt: 0xFFFFFF7F_BFC00000->0xFFFFFF7F_BFDFFFFF  : {}->{}, diff: 0x{x}", .{ indexFromVaddr(0xFFFFFF7F_BFC00000), indexFromVaddr(0xFFFFFF7F_BFDFFFFF), (0xFFFFFF7F_BFDFFFFF - 0xFFFFFF7F_BFC00000) });
    // // log.warn("pml4: 0xFFFFFF7F_BFDFE000 ->0xFFFFFF7F_BFDFEFFF   : {}->{}, diff:0x{x}", .{ indexFromVaddr(0xFFFFFF7F_BFDFE000), indexFromVaddr(0xFFFFFF7F_BFDFEFFF), (0xFFFFFF7F_BFDFEFFF - 0xFFFFFF7F_BFDFE000) });
    // // log.warn("pml4: 0xFFFFFF7F_BFDFE000 ->0xFFFFFF7F_BFDFEFFF   : {}->{}, diff:0x{x}", .{ indexFromVaddr(0xFFFFFF7F_BFDFE000), indexFromVaddr(0xFFFFFF7F_BFDFEFFF), (0xFFFFFF7F_BFDFEFFF - 0xFFFFFF7F_BFDFE000) });
    // //
    // // log.warn("\n\nkernel: {}->{}", .{ indexFromVaddr(0xffffff7f80000000), indexFromVaddr(0xffffff7f8009cb88) });
    // //
    // // const vmm_pml4_2 = tableFromVaddr(.pml4, 0xFFFFFF7F_BFDFFFFF) orelse @panic("Table not found");
    // // log.warn("vmm_pml4_2: 0xFFFFFF7F_BFDFE008 : {*}, len={d}, [0]={}@{*}, [511]={}@{*}", .{ vmm_pml4_2.ptr, vmm_pml4_2.len, vmm_pml4_2[0], &vmm_pml4_2[0], vmm_pml4_2[511], &vmm_pml4_2[511] });
    // //
    // // const vmm_pml4 = tableFromVaddr(.pml4, 0xFFFFFF7F_BFC00000) orelse @panic("Table not found [2a]");
    // // log.warn("vmm_pml4: 0xFFFFFF7F_BFC00000 : {*}, len={d}, [0]={}@{*}, [511]={}@{*}", .{ vmm_pml4.ptr, vmm_pml4.len, vmm_pml4[0], &vmm_pml4[0], vmm_pml4[511], &vmm_pml4[511] });
    // //
    // // const vmm_pdpt = tableFromVaddr(.pdpt, 0xFFFFFF7F_BFC00000) orelse @panic("Table not found [2b]");
    // // log.warn("vmm_pdpt: 0xFFFFFF7F_BFC00000 : {*}, len={d}, [0]={}@{*}, [511]={}@{*}", .{ vmm_pdpt.ptr, vmm_pdpt.len, vmm_pdpt[0], &vmm_pdpt[0], vmm_pdpt[511], &vmm_pdpt[511] });
    // //
    // // // recursive in 510, not 511 cause limine occupies it
    // // log.warn("cr3_formatted: {0}, {0b:0>40}, 0x{0x}", .{cr3_formatted.aligned_address_4kbytes});
    // // pml4t[510] = .{ .present = true, .writable = true, .aligned_address_4kbytes = @truncate(cr3_formatted.aligned_address_4kbytes) }; //we ignore the last bit
    // // cpu.invlpg(@intFromPtr(&pml4t[510]));
    // // log.err("&pml4[510]={*}", .{&pml4t[510]});
    // //
    // // //Dla PDPT
    // // // const pdpt_pidx = .{ .pml4_idx = 510, .pdpt_idx = 510, .pd_idx = 0, .pt_idx = 0, .offset = 0 };
    // // //  const pdpt510 = entryFromVaddr(.pdpt, vaddrFromIndex(pdpt_pidx));
    // // //  pdpt510.* = .{ .present = true, .writable = true, .aligned_address_4kbytes = @truncate(cr3_formatted.aligned_address_4kbytes) };
    // //
    // // //Dla PD
    // // // const pd_pidx = .{ .pml4_idx = 510, .pdpt_idx = 510, .pd_idx = 510, .pt_idx = 0, .offset = 0 };
    // // // const pd510 = entryFromVaddr(.pd, vaddrFromIndex(pd_pidx));
    // // // pd510.* = .{ .present = true, .writable = true, .aligned_address_4kbytes = @truncate(pdpt510.aligned_address_4kbytes) };
    // //
    // // // Dla PT
    // // // const pt_pidx = .{ .pml4_idx = 510, .pdpt_idx = 0, .pd_idx = 0, .pt_idx = 0, .offset = 0 };
    // // // const pt510 = entryFromVaddr(.pt, vaddrFromIndex(pt_pidx));
    // // // pt510.* = .{ .present = true, .writable = true, .aligned_address_4kbytes = @truncate(pd510.aligned_address_4kbytes) };
    // //
    // // // const pidx510: Index = .{ .pml4_idx = 510, .pdpt_idx = 0, .pd_idx = 0, .pt_idx = 0 , .offset = 0 };
    // // // const vaddr510 = vaddrFromIndex(pidx510);
    // // // log.warn("pidx510 -> {}", .{pidx510});
    // // // const pml4e510 = entryFromVaddr(.pml4, vaddr510);
    // // // log.warn("pml4e510: -> {}, ptr={*}", .{ pml4e510.*, pml4e510 });
    // //
    //print_tlb();
    // //
    // // // const tphys = physFromVirt(0xFFFFFF7F_8000000);
    // // // log.warn("tphys: 0x{x}", .{tphys});

}
