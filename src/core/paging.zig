const builtin = @import("builtin");

//pub usingnamespace switch (builtin.cpu.arch) {
const arch_paging = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/paging.zig"),
    else => |other| @compileError("Unimplemented for " ++ @tagName(other)),
};

const arch_cid = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/pcid.zig"),
    else => |other| @compileError("Unimplemented for " ++ @tagName(other)),
};

//re-export of key functions and constants
pub const default_page_size = arch_paging.default_page_size;
pub const init = arch_paging.init;
pub const deinit = arch_paging.deinit;
pub const hhdmVirtFromPhys = arch_paging.hhdmVirtFromPhys;
pub const downmapPageTables = arch_paging.downmapPageTables;
pub const adjustPageAreaPAT = arch_paging.adjustPageAreaPAT;

//re-export of additional functions
pub const logVirtInfo = arch_paging.logVirtInfo;
pub const logLowestEntryFromVirt = arch_paging.logLowestEntryFromVirt;

//new functions
pub fn physFromPtr(ptr: anytype) !usize {
    //return try @This().recPhysFromVirt(@intFromPtr(ptr));
    return arch_paging.physFromVirt(@intFromPtr(ptr));
}
