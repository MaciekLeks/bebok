const builtin = @import("builtin");

pub usingnamespace switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/start.zig"),
    else => |other| @compileError("Unimplemented for " ++ @tagName(other)),
};
