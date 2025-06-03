const builtin = @import("builtin");

pub usingnamespace switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/paging.zig"),
    else => |other| @compileError("Unimplemented for " ++ @tagName(other)),
};

// addons

pub fn physFromPtr(ptr: anytype) !usize {
    //return try @This().recPhysFromVirt(@intFromPtr(ptr));
    return @This().physFromVirt(@intFromPtr(ptr));
}
