const pmm = @import("pmm.zig");

pub const heap = struct {
    pub const page_allocator = pmm.allocator;
};