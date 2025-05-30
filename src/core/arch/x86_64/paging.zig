//! This is paging solely for 4-Level Paging, but it also supports 4-Kilobyte, 2-Megabyte, and 1-Gigabyte pages.
//! For now this code supports both recursive page table mapping and CR3-based page table mapping.
//! For recursive mapping, it uses 510 (not 511) in the PML4 table.
//! Virtual Address for Address Structure (octal)
//! Page 0o_SSSSSS_AAA_BBB_CCC_DDD_EEEE
//! Level 1 Table Entry PML4 0o_SSSSSS_RRR_AAA_BBB_CCC_DDDD
//! Level 2 Table Entry PDPT 0o_SSSSSS_RRR_RRR_AAA_BBB_CCCC
//! Level 3 Table Entry PD   0o_SSSSSS_RRR_RRR_RRR_AAA_BBBB
//! Level 4 Table Entry PT   0o_SSSSSS_RRR_RRR_RRR_RRR_AAAA,
//! where: SSSSSS is the sign extension of the 48-bit address, which means that they are all copies of bit 47
//! RRR is the index of the recursive entry
//! AAA is the index into the PML4 (lvl4) table
//! BBB is the index into the PDPT (lvl3) table
//! CCC is the index into the PD (lvl2) table
//! DDD is the index into the PT (lvl1) table
//! EEEE is the offset into the page

const std = @import("std");
const assert = std.debug.assert;

const config = @import("config");
const limine = @import("limine");

const cpu = @import("./cpu.zig");

const log = std.log.scoped(.paging);

const PageSize = enum(u32) {
    const Self = @This();

    ps4k = 0x1000,
    ps2m = 0x200000,
    ps1g = 0x40000000,

    pub fn gt(self: Self, other: Self) bool {
        return @intFromEnum(self) > @intFromEnum(other);
    }

    pub fn lt(self: Self, other: Self) bool {
        return @intFromEnum(self) < @intFromEnum(other);
    }
};

const PagingMode = enum(u1) {
    four_level = 0,
    five_level = 1,
};

const PageTableLevel = enum(u3) {
    l4 = 4, //pml4
    l3 = 3, //pdpt
    l2 = 2, //pd
    l1 = 1, //pt
};

const PagingState = struct {
    pcid_supported: bool = false,
    pcid_enabled: bool = false,
    invpcid_supported: bool = false,

    pub fn init() !PagingState {
        log.debug("PagingState::init", .{});
        defer log.debug("PagingState::init done", .{});
        var state: PagingState = .{
            .pcid_supported = isPcidSupported(),
            .pcid_enabled = isPcidEnabled(),
            .invpcid_supported = cpu.Id.isInvpcidSupported(),
        };

        // If PCID is supported but not enabled, attempt to enable it
        if (state.pcid_supported and !state.pcid_enabled) {
            log.debug("PagingState:: PCID supported but not enabled, attempting to enable...", .{});

            cpu.Cr4.enablePcid() catch |err| switch (err) {
                error.PcidNotSupported => {
                    log.warn("PagingState:: Failed to enable PCID: not supported", .{});
                    return err;
                },
            };

            if (cpu.Cr4.isPcidEnabled()) state.pcid_enabled = true else {
                log.err("PagingState: Failed to enable PCID", .{});
                return error.PcidNotEnabled;
            }
        }

        log.debug("PagingState:: PCID is enabled, current PCID: {d}", .{getCurrentPcid()});

        return state;
    }

    fn isPcidSupported() bool {
        return cpu.Id.isPcidSupported();
    }

    fn isPcidEnabled() bool {
        return cpu.Cr4.isPcidEnabled();
    }

    fn getCurrentPcid() u12 {
        if (!isPcidEnabled()) return 0;
        const cr3_val = cpu.Cr3.read();
        const cr3_pcid = cpu.Cr3.FormattedWithPcid(true).fromRaw(cr3_val);
        return cr3_pcid.pcid;
    }

    fn getCurrentCr3() u64 {
        return cpu.Cr3.read();
    }
};

//constants
pub const default_page_size: PageSize = @enumFromInt(config.mem_page_size);
const entries_count: usize = 512;
const default_recursive_index: u9 = 510; //0x1FE
const page_table_levels = [_]PageTableLevel{ .l4, .l3, .l2, .l1 };

//variables
pub export var hhdm_request: limine.HhdmRequest = .{};
pub export var paging_mode_request: limine.PagingModeRequest = .{ .mode = .four_level, .flags = 0 }; //default L4 paging
var hhdm_offset: usize = undefined;

//types
const RawEntry = u64;
///Info on physical address placement in the page table
const PhysInfo = struct {
    phys_base: usize, //4K aligned
    phys: usize, //phys_base + offset
    lvl: PageTableLevel,
    ps: PageSize,
};

// the lowest level entry stoing the frame address
fn LeafEntryTypeFromPageSize(comptime ps: PageSize) type {
    return switch (ps) {
        .ps4k => L1Entry,
        .ps2m => L2Entry2M,
        .ps1g => L3Entry1G,
    };
}

fn LeafEntryTypeFromLevel(comptime lvl: PageTableLevel) type {
    return switch (lvl) {
        .l4 => unreachable,
        .l3 => L3Entry1G,
        .l2 => L2Entry2M,
        .l1 => L1Entry,
    };
}

pub const GenEntryInfo = struct {
    entry_ptr: ?*RawEntry = null,
    lvl: ?PageTableLevel = null,
    ps: ?PageSize = null,
};

// TODO: usngnamespace does not work in case of the fields
pub fn GenPageEntry(comptime ps: PageSize, comptime lvl: PageTableLevel) type {
    //return packed struct(GenericEntry) {
    return switch (lvl) {
        .l4 => packed struct(RawEntry) {
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

            pub inline fn getPhysBase(self: Self) usize {
                return @as(usize, self.aligned_address_4kbytes) << 12;
            }

            //Depreciated
            pub fn retrieveTable(self: Self) ?[]L3Entry {
                return if (self.present) @as(*L3Table, @ptrFromInt(hhdmVirtFromPhys(self.aligned_address_4kbytes << @bitSizeOf(u12)))) else null;
            }
        },
        // .pdpte1gbytes
        .l3 => switch (ps) {
            .ps1g => packed struct(RawEntry) {
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

                pub inline fn getPhysBase(self: Self) usize {
                    return @as(usize, self.aligned_address_1gbytes) << 30;
                }

                //Depreciated
                pub inline fn retrieveFrameVirt(self: Self) ?usize {
                    return if (self.present) self.aligned_address_1gbytes else null;
                }

                //Depreciated
                pub inline fn retrieveFrame(self: Self) ?[]usize {
                    return if (self.present) @as(*[.ps1g]RawEntry, @ptrFromInt(self.retrieveFrameVirt().?)) else null;
                }
            },
            //.ps4k, .ps2m => packed struct(RawEntry) {
            else => packed struct(RawEntry) {
                const Self = @This();
                present: bool = false, //0
                writable: bool = false, //1
                user: bool = false, //2
                write_through: bool = false, //3
                cache_disabled: bool = false, //4
                accessed: bool = false, //5
                ignrd_a: u1 = 0, //6
                huge: bool = false, //7
                ignrd_b: u3 = 0, //8-10
                restart: u1 = 0, //11
                aligned_address_4kbytes: u39, //12-50
                rsrvd_a: u1 = 0, //50
                ignr_b: u11 = 0, //52-62
                execute_disable: bool = false, //63

                pub inline fn getPhysBase(self: Self) usize {
                    return @as(usize, self.aligned_address_4kbytes) << 12;
                }

                //Depreciated
                pub inline fn retrieveTable(self: Self) ?[]L2Entry {
                    return if (self.present) @as(*L2Table, @ptrFromInt(hhdmVirtFromPhys(self.aligned_address_4kbytes << @bitSizeOf(u12)))) else null;
                }
            },
            //            else => @compileError("Unsupported page size:" ++ @tagName(ps)),
        },
        .l2 => switch (ps) {
            .ps2m => packed struct(RawEntry) {
                const Self = @This();
                present: bool = false, //0
                writable: bool = false, //1
                user: bool = false, //2
                write_through: bool = false, //3
                cache_disabled: bool = false, //4
                accessed: bool = false, //5
                dirty: bool = false, //6
                huge: bool = false, //7
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

                pub inline fn getPhysBase(self: Self) usize {
                    return @as(usize, self.aligned_address_2mbytes) << 30;
                }

                //Depreciated
                pub inline fn retrieveFrameVirt(self: Self) ?usize {
                    return if (self.present) self.aligned_address_2mbytes else null;
                }

                //Depreciated
                pub inline fn retrievFrame(self: Self) ?[]usize {
                    return if (self.present) @as(*[.ps2m]usize, @ptrFromInt(self.retrieveFrameVirt().?)) else null;
                }
            },
            //.ps4k => packed struct(RawEntry) {
            else => packed struct(RawEntry) {
                const Self = @This();
                present: bool = false, //0
                writable: bool = false, //1
                user: bool = false, //2
                write_through: bool = false, //3
                cache_disabled: bool = false, //4
                accessed: bool = false, //5
                ignrd_a: bool = false, //6
                huge: bool = false, //7 //must be 0
                ignrd_b: u3 = 0, //8-10
                restart: u1 = 0, //11
                aligned_address_4kbytes: u39, //12-50
                rsrvd_a: u1 = 0, //51-51 //must be 0
                ignrd_c: u11 = 0, //52-62
                execute_disable: bool = true, //63

                pub inline fn getPhysBase(self: Self) usize {
                    return @as(usize, self.aligned_address_4kbytes) << 12;
                }

                //Depreciated
                pub inline fn retrieveTable(self: Self) ?[]L1Entry {
                    return if (self.present) @as(*L1Table, @ptrFromInt(hhdmVirtFromPhys(self.aligned_address_4kbytes << @bitSizeOf(u12)))) else null;
                }
            },
            //else => @compileError("Unsupported page size:" ++ ps),
        },
        .l1 => packed struct(RawEntry) {
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
            protection_key: u4 = 0, //5 w9-62
            execute_disable: bool = false, //63

            pub inline fn getPhysBase(self: Self) usize {
                return @as(usize, self.aligned_address_4kbytes) << 12;
            }

            //Depreciated
            pub inline fn retrieveFrameVirt(self: Self) ?usize {
                return if (self.present) self.aligned_address_4kbytes else null;
            }

            //Depreciated
            pub inline fn retrieveFrame(self: Self) ?[]usize {
                return if (self.present) @as(*[@intFromEnum(PageSize.ps4k)]RawEntry, @ptrFromInt(self.retrieveFrameVirt().?)) else null;
            }
        },
    };
}

// Generic function for GenPageEntry
inline fn isLeaf(entry: anytype, comptime lvl: PageTableLevel) !bool {
    if (!entry.present) return error.PageFault;

    return switch (lvl) {
        .l4 => false, // PML4 is never a leaf
        .l3 => entry.huge, // PDPT is leaf if huge=true (1GB page)
        .l2 => entry.huge, //
        .l1 => true, // PT is always a leaf
    };
}

inline fn pageSizeFromLevel(comptime lvl: PageTableLevel) PageSize {
    return switch (lvl) {
        .l4 => unreachable,
        .l3 => .ps1g,
        .l2 => .ps2m,
        .l1 => .ps4k,
    };
}

fn physFromVA(entry: anytype, va: VirtualAddress, comptime lvl: PageTableLevel) usize {
    return switch (lvl) {
        .l4 => entry.getPhysBase() + va.getPageOffset(.ps4k),
        .l3 => if (entry.huge)
            entry.getPhysBase() + va.getPageOffset(.ps1g)
        else
            entry.getPhysBase() + va.getPageOffset(.ps4k),
        .l2 => if (entry.huge)
            entry.getPhysBase() + va.getPageOffset(.ps2m)
        else
            entry.getPhysBase() + va.getPageOffset(.ps4k),
        .l1 => entry.getPhysBase() + va.getPageOffset(.ps4k),
    };
}

pub const L4Entry = GenPageEntry(default_page_size, .l4);
pub const L3Entry = GenPageEntry(default_page_size, .l3);
pub const L3Entry1G = GenPageEntry(.ps1g, .l3);
pub const L2Entry = GenPageEntry(default_page_size, .l2);
pub const L2Entry2M = GenPageEntry(.ps2m, .l2);
pub const L1Entry = GenPageEntry(default_page_size, .l1);
pub const L4Table = [entries_count]L4Entry;
pub const L3Table = [entries_count]L3Entry;
pub const L2Table = [entries_count]L2Entry;
pub const L1Table = [entries_count]L1Entry;

const VirtualAddress = packed struct(u64) {
    const Self = @This();

    disp: u12 = 0, //displacement 12 bites for 4k pages, for 2m and 1g pages is only a part of the whole 21bits or 30bits offsets
    l1idx: u9 = 0, //pt // for 1GB pages is a high part of the index
    l2idx: u9 = 0, //pd //for 1GB and 2MB pages is higher part of the index
    l3idx: u9 = 0, //pdpt
    l4idx: u9 = 0, //pml4
    rsvrd: u16 = 0, //replicated bit 47

    pub fn fromUsize(virt_addr: usize) VirtualAddress {
        log.debug("Downmap::fromUsize: virt_addr:0x{x}", .{virt_addr});
        return @as(VirtualAddress, @bitCast(virt_addr));
    }

    pub fn toUsize(self: *const Self) usize {
        return @as(usize, @bitCast(self.*));
    }

    pub fn asPtr(self: *const Self, comptime T: type) T {
        const ptr_ti = @typeInfo(T);
        if (ptr_ti != .pointer) @compileError("Only pointer type is supported in the ImplPtr argument");

        return @ptrFromInt(@as(usize, @bitCast(self.*)));
    }

    /// Create a VirtualAddress from a raw usize value with a given 12bits offset.
    pub fn withDisp(self: *const Self, disp: u12) VirtualAddress {
        var new = self.*;
        new.disp = disp;
        return new;
    }

    /// Returns the page offset based on the page size.
    pub inline fn getPageOffset(self: *const Self, comptime page_size: PageSize) switch (page_size) {
        .ps4k => u12,
        .ps2m => u21,
        .ps1g => u30,
    } {
        return switch (page_size) {
            .ps4k => self.disp,
            .ps2m => @truncate(@as(usize, @bitCast(self.*))),
            .ps1g => @truncate(@as(usize, @bitCast(self.*))),
        };
    }

    pub inline fn idxFromLvl(self: Self, comptime lvl: PageTableLevel) usize {
        return switch (lvl) {
            .l4 => self.l4idx,
            .l3 => self.l3idx,
            .l2 => self.l2idx,
            .l1 => self.l1idx,
        };
    }

    // Use it only to shift indexes in recursive indexing to go down the lower level
    pub fn recursiveShiftLeftIndexes(self: *const Self, offset: u12) VirtualAddress {
        var res = self.*;
        res.l4idx = self.l3idx;
        res.l3idx = self.l2idx;
        res.l2idx = self.l1idx;
        res.l1idx = @intCast(self.disp);
        res.disp = offset;

        return res;
    }

    pub fn recursiveL4() VirtualAddress {
        return VirtualAddress{
            .disp = 0,
            .l1idx = default_recursive_index,
            .l2idx = default_recursive_index,
            .l3idx = default_recursive_index,
            .l4idx = default_recursive_index,
            .rsvrd = 0xFFFF,
        };
    }

    pub fn recursiveL3(l4_idx: u9) VirtualAddress {
        return VirtualAddress{
            .disp = 0,
            .l1idx = l4_idx,
            .l2idx = default_recursive_index,
            .l3idx = default_recursive_index,
            .l4idx = default_recursive_index,
            .rsvrd = 0xFFFF,
        };
    }

    pub fn recursiveL2(l4_idx: u9, l3_idx: u9) VirtualAddress {
        return VirtualAddress{
            .disp = 0,
            .l1idx = l3_idx,
            .l2idx = l4_idx,
            .l3idx = default_recursive_index,
            .l4idx = default_recursive_index,
            .rsvrd = 0xFFFF,
        };
    }

    pub fn recursiveL1(l4_idx: u9, l3_idx: u9, l2_idx: u9) VirtualAddress {
        return VirtualAddress{
            .disp = 0,
            .l1idx = l2_idx,
            .l2idx = l3_idx,
            .l3idx = l4_idx,
            .l4idx = default_recursive_index,
            .rsvrd = 0xFFFF,
        };
    }

    pub fn recursive(level: PageTableLevel, indices: anytype) VirtualAddress {
        return switch (level) {
            .l4 => Self.recursiveL4(),
            .l3 => Self.recursiveL3(indices[0]),
            .l2 => Self.recursiveL2(indices[0], indices[1]),
            .l1 => Self.recursiveL1(indices[0], indices[1], indices[2]),
        };
    }

    pub fn isRecursive(self: *const Self) bool {
        // Che,geck if the address is recursive
        return self.l4idx == default_page_size and self.rsvrd == 0xFFFF;
    }
};

/// Use this if there is no need to get the whole Index
pub inline fn idxFromVirt(virt: usize, lvl: PageTableLevel) usize {
    const shift_amount = 12 + (@intFromEnum(lvl) - 1) * 9;
    return (virt >> shift_amount) & 0x1FF;
}

/// Next level of the page table
fn nextLevel(comptime lvl: PageTableLevel) PageTableLevel {
    return switch (lvl) {
        .l4 => .l3,
        .l3 => .l2,
        .l2 => .l1,
        .l1 => unreachable,
    };
}

// Do not use it with recursive virtual addresses!
fn pageSliceFromVA(comptime lvl: PageTableLevel, va: VirtualAddress) switch (lvl) {
    .l4 => []L4Entry,
    .l3 => []L3Entry,
    .l2 => []L2Entry,
    .l1 => []L1Entry,
} {
    return switch (lvl) {
        .l4 => VirtualAddress.recursiveL4().asPtr(*L4Table)[0..entries_count],
        .l3 => VirtualAddress.recursiveL3(va.l4idx).asPtr(*L3Table)[0..entries_count],
        .l2 => VirtualAddress.recursiveL2(va.l4idx, va.l3idx).asPtr(*L2Table)[0..entries_count],
        .l1 => VirtualAddress.recursiveL1(va.l4idx, va.l3idx, va.l2idx).asPtr(*L1Table)[0..entries_count],
    };
}

// Only for recursive virtual address
fn pageSliceFromVARecursive(comptime lvl: PageTableLevel, rec_virt_addr: VirtualAddress) switch (lvl) {
    .l4 => []L4Entry,
    .l3 => []L3Entry,
    .l2 => []L2Entry,
    .l1 => []L1Entry,
} {
    return switch (lvl) {
        .l4 => rec_virt_addr.asPtr(*L4Table)[0..entries_count],
        .l3 => rec_virt_addr.asPtr(*L3Table)[0..entries_count],
        .l2 => rec_virt_addr.asPtr(*L2Table)[0..entries_count],
        .l1 => rec_virt_addr.asPtr(*L1Table)[0..entries_count],
    };
}

/// Do not use it on recursive page tables!
pub fn physInfoFromVirt(virt: usize) !PhysInfo {
    const va = VirtualAddress.fromUsize(virt);
    log.debug("Downmapping::physInfoFromVirt: virt:0x{x} va:{any}", .{ virt, va });

    inline for (page_table_levels) |lvl| {
        const curr_table = pageSliceFromVA(lvl, va);
        const idx = va.idxFromLvl(lvl);
        const entry = curr_table[idx];
        if (!entry.present) {
            log.debug("Downmapping::physInfoFromVirt: entry not present at lvl:{s} idx:{d}", .{ @tagName(lvl), idx });
            return error.PageFault;
        }

        if (try isLeaf(entry, lvl)) {
            return .{ .phys_base = entry.getPhysBase(), .phys = physFromVA(entry, va, lvl), .lvl = lvl, .ps = pageSizeFromLevel(lvl) };
        }
    }

    log.debug("Downmapping::physInfoFromVirt: no leaf entry found for virt:0x{x}", .{virt});
    return error.PageFault;
}

pub inline fn physFromVirt(virt: usize) !usize {
    const info = try physInfoFromVirt(virt);
    return info.phys;
}

const RemapperInfo = struct {
    ps1g_count: usize = 0,
    ps2m_count: usize = 0,
    ps4k_count: usize = 0,

    pub fn inc(self: *RemapperInfo, tps: PageSize) void {
        switch (tps) {
            .ps4k => self.ps4k_count += 1,
            .ps2m => self.ps2m_count += 1,
            .ps1g => self.ps1g_count += 1,
        }
    }
};

pub fn downmapPageTables(comptime tps: PageSize, allocator: std.mem.Allocator) !void {
    comptime {
        if (tps == .ps1g) @compileError("Downmapping to 1GB page is not supported");
    }

    log.debug("Downmapping page tables to {any}", .{tps});
    defer log.debug("Downmapping page tables to {any} done", .{tps});

    var remapper_info: RemapperInfo = .{};

    const old_l4 = pageSliceFromVARecursive(.l4, VirtualAddress.recursiveL4());
    const new_l4 = try dupePageTable(L4Entry, allocator, old_l4, tps, &remapper_info);

    // set recursive L4 address
    log.debug("Downmapping::dupePageTable: old_l4_ptr: {*}, new_l4_ptr: {*}", .{ old_l4, new_l4 });
    const new_l4_phys = try physFromVirt(@intFromPtr(new_l4.ptr));
    new_l4[default_recursive_index].aligned_address_4kbytes = @truncate(new_l4_phys >> 12);

    // set l4_table address in CR3
    // TODO:

    log.debug("Downmapping info: {any}", .{remapper_info});
}

fn dupePageTable(comptime T: type, allocator: std.mem.Allocator, src: []T, comptime tps: PageSize, remapper_info: *RemapperInfo) ![]T {
    // no matter what page size we need to allocate 4kbytes aligned page, but if you use for instance Arena Allocator, then
    // we do not control the alignment, so it is better to aligned imperatively
    const dst = allocator.allocWithOptions(T, entries_count, std.mem.Alignment.fromByteUnits(@intFromEnum(PageSize.ps4k)), null) catch |err| {
        log.err("Failed to allocate page table: {any}", .{err});
        return error.PageFault;
    };
    @memset(@as([*]u8, @ptrCast(dst.ptr))[0 .. @sizeOf(T) * entries_count], 0);
    log.debug("Downmapping::dupePageTable: new dst_ptr: {*}", .{dst});

    for (src, dst) |src_entry, *dst_entry| {
        if (!src_entry.present) {
            dst_entry.* = src_entry;
            continue;
        }

        switch (T) {
            L4Entry => {
                const src_l3 = getSliceFromEntry(L3Entry, src_entry);
                const new_l3 = try dupePageTable(L3Entry, allocator, src_l3, tps, remapper_info);

                dst_entry.* = src_entry;
                log.debug("Downmapping::dupePageTable @@@L4/1", .{});
                dst_entry.aligned_address_4kbytes = @truncate(try physFromVirt(@intFromPtr(new_l3.ptr)) >> 12);
                log.debug("Downmapping::dupePageTable @@@L4/2", .{});
            },
            L3Entry => {
                if (!try isLeaf(src_entry, .l3)) {
                    const src_l2 = getSliceFromEntry(L2Entry, src_entry);
                    const new_l2 = try dupePageTable(L2Entry, allocator, src_l2, tps, remapper_info);

                    dst_entry.* = src_entry;
                    log.debug("Downmapping::dupePageTable @@@L3/1", .{});
                    dst_entry.aligned_address_4kbytes = @truncate(try physFromVirt(@intFromPtr(new_l2.ptr)) >> 12);
                    log.debug("Downmapping::dupePageTable @@@L3/2", .{});
                } else {
                    if (tps.lt(.ps1g)) {
                        log.debug("Downmap: L3Entry is leaf, but tps < 1GB, so we need to downmap it. src_entry:{any}", .{src_entry});
                        //TODO: implement downmapping for 1GB page to smaller size
                        return error.NotImplemented; // cannot downmap 1GB page to smaller size
                    } else

                    //update statistics
                    remapper_info.inc(.ps1g);
                }
            },
            L2Entry => {
                if (!try isLeaf(src_entry, .l2)) {
                    const src_l1 = getSliceFromEntry(L1Entry, src_entry);
                    const new_l1 = try dupePageTable(L1Entry, allocator, src_l1, tps, remapper_info);

                    dst_entry.* = src_entry;
                    log.debug("Downmapping::dupePageTable @@@L2/1", .{});
                    dst_entry.aligned_address_4kbytes = @truncate(try physFromVirt(@intFromPtr(new_l1.ptr)) >> 12);
                    log.debug("Downmapping::dupePageTable @@@L2/2 dst_entry:{any}", .{dst_entry.*});
                } else {
                    if (tps.lt(.ps2m)) {
                        dst_entry.* = try downmap2MBPage(allocator, @bitCast(src_entry));
                    } else {
                        dst_entry.* = src_entry; // Stay as is, no downmapping needed
                    }

                    //update statistics
                    remapper_info.inc(.ps1g);
                }
            },
            L1Entry => {
                log.debug("Downmapping::dupePageTable @@@L1/1", .{});
                dst_entry.* = src_entry;

                //update statistics
                remapper_info.inc(.ps4k);
            },
            else => @compileError("Unsupported page table type: " ++ @typeName(T)),
        }
    }

    return dst;
}

fn downmap2MBPage(allocator: std.mem.Allocator, l2m_entry: L2Entry2M) !L2Entry {
    log.debug("Downmapping::downmap2MBPage: l2m_entry: {any}", .{l2m_entry});

    var new_l2_entry: L2Entry = @bitCast(l2m_entry);
    const l2m_entry_phys = l2m_entry.getPhysBase();

    defer log.debug("Downmapping::downmap2MBPage done: new_l2_entry: {any}", .{new_l2_entry});

    // Create a new page tables (512 tables of the 4KB size) for 4KB pages
    const new_l1 = try allocator.alignedAlloc(L1Entry, std.mem.Alignment.fromByteUnits(@intFromEnum(PageSize.ps4k)), entries_count);
    @memset(@as([*]u8, @ptrCast(new_l1.ptr))[0 .. @sizeOf(L1Entry) * entries_count], 0);

    // 2MB → 4KB (512 entries)
    for (0..entries_count) |i| {
        new_l1[i] = L1Entry{
            .present = l2m_entry.present,
            .writable = l2m_entry.writable,
            .user = l2m_entry.user,
            .write_through = l2m_entry.write_through,
            .cache_disabled = l2m_entry.cache_disabled,
            .accessed = l2m_entry.accessed,
            .dirty = l2m_entry.dirty,
            .pat = l2m_entry.pat,
            .global = l2m_entry.global,
            .restart = l2m_entry.restart,
            .aligned_address_4kbytes = @truncate((l2m_entry_phys + i * @intFromEnum(PageSize.ps4k)) >> 12),
            .protection_key = l2m_entry.protection_key,
            .execute_disable = l2m_entry.execute_disable,
        };
    }

    new_l2_entry.aligned_address_4kbytes = @truncate((try physFromVirt(@intFromPtr(new_l1.ptr))) >> 12);

    return new_l2_entry;
}

// fn downmapPageTablesRecursive(comptime lvl: PageTableLevel, comptime tps: PageSize, allocator: std.mem.Allocator, rec_va: VirtualAddress, remapper_info: *RemapperInfo) !void {
//     log.debug("\n\nDownmap::start lvl:{s} rec_va(0x{x}):{any}", .{ @tagName(lvl), rec_va.toUsize(), rec_va });

//     //get page table slice
//     const table = pageSliceFromVARecursive(lvl, rec_va);

//     var i: u10 = 0; //must be u(9+1) to stop at 512
//     while (i < entries_count) : (i += 1) {
//         const entry_ptr = &table[i];
//         const curr_va = rec_va.withDisp(i);

//         if (!entry_ptr.present) continue;

//         //log.debug("Downmap::entry[{d}] lvl:{s} -> entry[{d}]: {any} ", .{ i, @tagName(lvl), i, entry_ptr.* });

//         if (try isLeaf(entry_ptr.*, lvl)) {
//             //get physical address info
//             //const phys_info = try physInfoFromVirt(curr_virt);

//             const ps = pageSizeFromLevel(lvl);

//             log.debug("Downmap::isLeaf lvl:{s} -> ps: {s} -> entry@{any}: {any}", .{ @tagName(lvl), @tagName(ps), curr_va, entry_ptr.* });

//             remapper_info.inc(ps);
//             // //downmap the page entry if it too big
//             if (ps.gt(tps)) {
//                 //log.debug("Downmap phys.info.ps > tps", .{});
//             }
//         } else if (lvl != .l1) {
//             const next_rec_va = curr_va.recursiveShiftLeftIndexes(0);
//             try downmapPageTablesRecursive(nextLevel(lvl), tps, allocator, next_rec_va, remapper_info);
//         }
//     }
// }

// fn dupePageStructTable(comptime T: type, allocator: std.mem.Allocator, src: []T) ![]T {
//     // no matter what page size we need to allocate 4kbytes aligned page, but if you use for instance Arena Allocator, then
//     // we do not controll the alignment, so it is better to aligned imperatively
//     const dst = allocator.allocWithOptions(T, entries_count, @intFromEnum(PageSize.ps4k), null) catch |err| {
//         log.err("Failed to allocate page table: {any}", .{err});
//         return error.PageFault;
//     };
//     @memcpy(dst.ptr, src);
//     return dst;
// }

inline fn getSliceFromEntry(comptime TableType: type, entry: anytype) []TableType {
    return @as(*[entries_count]TableType, @ptrFromInt(hhdmVirtFromPhys(entry.getPhysBase())))[0..entries_count];
}

inline fn getSliceFromAlignedPhys(comptime TableType: type, alignment: comptime_int, phys_addr: usize) []TableType {
    return @as(*[entries_count]TableType, @ptrFromInt(hhdmVirtFromPhys(phys_addr << alignment)))[0..entries_count];
}

/// Get the lowest page entry info from the virtual address;
/// If some part of the information is not available, it will be null.
fn getLowestEntryFromVirt(virt: usize) !GenEntryInfo {
    const va = VirtualAddress.fromUsize(virt);
    var res: GenEntryInfo = .{};
    log.debug("getLowestEntryFromVirt start: virt:0x{x} va:{any}", .{ virt, va });
    defer log.debug("getLowestEntryFromVirt done: virt:0x{x} va:{any} -> res: {any}", .{ virt, va, res });

    inline for (page_table_levels) |lvl| {
        const curr_table = pageSliceFromVA(lvl, va);
        const idx = va.idxFromLvl(lvl);
        const entry_ptr = &curr_table[idx];
        if (!entry_ptr.present) return error.PageFault;

        res.entry_ptr = @ptrCast(@alignCast(entry_ptr));
        res.lvl = lvl;

        if (try isLeaf(entry_ptr, lvl)) {
            res.ps = pageSizeFromLevel(lvl);
            return res;
        }
    }

    return res;
}

/// Get virtual address from paging indexes using Higher Half Direct Mapping offset
pub inline fn hhdmVirtFromPhys(paddr: usize) usize {
    return paddr + hhdm_offset;
}

/// Get physical address from the cr3 registry. This function is not needed in the recursive paging.
// fn Pml4TableFromCr3() struct { []L4Entry, Cr3Structure(false) } {
//     const cr3_formatted: Cr3Structure(false) = @bitCast(cpu.cr3());
//     return .{ cr3_formatted.retrieve_table(L4Table), cr3_formatted };
// }

pub fn logLowestEntryFromVirt(virt: usize) void {
    const page_entry_info = getLowestEntryFromVirt(virt) catch @panic("Failed to get page entry info for NVMe BAR");
    log.debug("page entry info: {} ", .{page_entry_info});

    if (page_entry_info.entry_ptr == null) {
        log.err("Entry not found for virt: 0x{x}", .{virt});
        return;
    }
    if (page_entry_info.ps == null) {
        log.err("Page size not found for virt: 0x{x}", .{virt});
        return;
    }
    switch (page_entry_info.ps.?) {
        .ps1g => {
            const entry: *L3Entry1G = @ptrCast(page_entry_info.entry_ptr);
            log.debug(".ps1g entry: {any}", .{entry});
        },
        .ps2m => {
            const entry: *L2Entry2M = @ptrCast(page_entry_info.entry_ptr);
            log.debug(".ps2m entry: {any}", .{entry});
        },
        .ps4k => {
            const entry: *L1Entry = @ptrCast(page_entry_info.entry_ptr);
            log.debug(".ps4k entry: {any}", .{entry});
        },
    }
}

pub fn logVirtInfo(virt: usize) void {
    log.err("logVirtInfo: Virtual Adddress to check: 0x{x}", .{virt});

    const vaddr_info = getLowestEntryFromVirt(virt) catch |err| {
        log.err("logVirtInfo: Call function getLowestEntryFromVirt: 0x{x} -> error: {}", .{ virt, err });
        return;
    };

    log.debug("Paging Table:  0x{x} -> {any}", .{ virt, vaddr_info });
    const phys_by_rec = physFromVirt(virt) catch |err| {
        log.err("logVirtInfo: Call function recPhysFromVirt: 0x{x} -> error: {}", .{ virt, err });
        return;
    };
    log.debug("logVirtInfo: Call function recPhyFromVirt: virt: 0x{x} -> 0x{x}\n", .{ virt, phys_by_rec });
}

// Variables
//var/ pml4t: []L4Entry = undefined;
var pat: PAT = undefined;
var paging_state: PagingState = undefined;

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

    paging_state = try PagingState.init();

    //We assume having PCID enabled, so we can use it
    const cr3 = cpu.Cr3.FormattedWithPcid(true).fromRaw(cpu.Cr3.read());

    // Get ready for recursive paging
    const l4: []L4Entry = getSliceFromAlignedPhys(L4Entry, @bitSizeOf(u12), cr3.aligned_address_4kbytes);
    l4[default_recursive_index] = .{ .present = true, .writable = true, .aligned_address_4kbytes = cr3.aligned_address_4kbytes };

    //const lvl4e = retrieveEntryFromVaddr(Pml4e, .four_level, default_page_size, .lvl4, 0xffff_8000_fe80_0000);
    log.warn("cr3 -> {any}", .{cr3});

    //TODO: remove this code, it is only for testing purposes
    const vt = [_]usize{
        hhdmVirtFromPhys(0x4d00), //HHDM
        //hhdmVirtFromPhys(0x10_0000),
        hhdmVirtFromPhys(0x7fa61000),
        //?hhdmVirtFromPhys(0x7fa61001),
        //hhdmVirtFromPhys(0x7fa63000),
        //?hhdmVirtFromPhys(0xfee0_0000),
        //?0xffffff7fa0003ff8,
        //0xffffff4020100000,
        //0xffffff7fa0100000,
        //0xffffff7fbfdfe000,
        //0xffffff7fbfd00000,
    };
    for (vt) |vaddr| {
        const psych_info = physInfoFromVirt(vaddr) catch |err| {
            log.err("Call function physInfoFromVirt: 0x{x} -> error: {}", .{ vaddr, err });
            continue;
        };
        log.debug("Call function physInfoFromVirt: 0x{x} -> {any}", .{ vaddr, psych_info });
    }
}

// PAT (Page Attribute Table) specific code
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

fn retrievePagePAT(page_entry_info: GenEntryInfo) PATType {
    // we now have the ps and entry_ptr, so we can retrieve the PAT type
    switch (page_entry_info.ps.?) {
        inline else => |ps| {
            const entry: *LeafEntryTypeFromPageSize(ps) = @ptrCast(page_entry_info.entry_ptr);
            return pat.patFromPageFlags(entry.pat, entry.cache_disabled, entry.write_through);
        },
    }
}

fn setPagePAT(page_entry_info: GenEntryInfo, req_pat: PATType) void {
    const page_req_pat_flags = pat.pageFlagsFromPat(req_pat);
    // we now have the ps and entry_ptr, so we can set the PAT type
    switch (page_entry_info.ps.?) {
        inline else => |ps| {
            const entry: *LeafEntryTypeFromPageSize(ps) = @ptrCast(page_entry_info.entry_ptr);
            entry.pat = page_req_pat_flags.page_pat;
            entry.cache_disabled = page_req_pat_flags.page_pcd;
            entry.write_through = page_req_pat_flags.page_pwt;
        },
    }
}

fn adjustPagePAT(virt: usize, page_entry_info: GenEntryInfo, req_pat: PATType) void {
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
    const pg_entry_info = try getLowestEntryFromVirt(virt);
    if (pg_entry_info.ps == null) return error.InvalidPageSize;

    const pg_sz = @intFromEnum(pg_entry_info.ps.?);
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
    cpu.Cr3.invlpg(virt);
}
