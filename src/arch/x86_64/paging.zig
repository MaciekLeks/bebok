const limine = @import("limine");
const std = @import("std");
const assm = @import("asm.zig");

/// Holds indexes of all paging tables
/// each table holds indexes of 512 entries, so we need only 9 bytes to store index
/// Offset is 12 bits to address 4KiB page
const PagingIndex = struct {
    pml4: u9,
    pdpt: u9,
    pd: u9,
    pt: u9,
    offset: u12,
};

pub export var hhdm_request: limine.HhdmRequest = .{};
var hhdm_offset: usize = undefined;

const log = std.log.scoped(.paging);

/// Get paging indexes from virtual address
/// It maps 48-bit virtual address to 9-bit indexes of all 52 physical address bits
/// src osdev: "Virtual addresses in 64-bit mode must be canonical, that is,
/// the upper bits of the address must either be all 0s or all 1s.
// For systems supporting 48-bit virtual address spaces, the upper 16 bits must be the same"
pub inline fn pagingIndexFromVaddr(vaddr: usize) PagingIndex {
    return .{
        .pml4 = @truncate(vaddr >> 39), //48->39
        .pdpt = @truncate(vaddr >> 30), //39->30
        .pd = @truncate(vaddr >> 21), //30->21
        .pt = @truncate(vaddr >> 12), //21->12
        .offset = @truncate(vaddr), //12 bites
    };
}

test pagingIndexFromVaddr {
    try std.testing.expect(PagingIndex{
        .pml4 = 0,
        .pdpt = 0,
        .pd = 0,
        .pt = 2,
        .offset = 1,
    }, pagingIndexFromVaddr(0x2001));
}

/// Get virtual address from paging indexes using Higher Half Direct Mapping offset
pub inline fn vaddrFromPaddr(paddr: usize) usize {
    return paddr + hhdm_offset;
}

pub fn init() void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialized", .{});

    if (hhdm_request.response) |hhdm_response| {
        hhdm_offset = hhdm_response.offset;
        log.debug("HHDM offset: 0x{x}", .{hhdm_offset});
    } else @panic("No HHDM bootloader response available");

    const vaddr = assm.cr3();
    log.info("cr3: 0x{x}", .{vaddr});
    log.info("vaddr: 0x0 -> {any}", .{pagingIndexFromVaddr(0)});
    log.info("vaddr: 0x2000 -> {any}", .{pagingIndexFromVaddr(0x2001)});
}
