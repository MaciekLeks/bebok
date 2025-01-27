// src/test_root.zig
//pub usingnamespace @import("kernel.zig");
pub const ext2 = @import("ext2");

pub fn myRefAllDecls(comptime T: type) void {
    const std = @import("std");
    inline for (comptime std.meta.declarations(T)) |decl| {
        std.debug.print("Decl type: {}\n", .{@TypeOf(@field(T, decl.name))});
        if (@TypeOf(@field(T, decl.name)) == type) {
            std.debug.print("--Type name: {}\n", .{@field(T, decl.name)});
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => myRefAllDecls(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
        std.debug.print("Ref: {s}\n", .{decl.name});
    }
}

test "my_test_a" {
    @import("std").debug.print("Hello, world from my_test_a: {d}!\n", .{ext2.ext2_pub_fn(1)});
}

test {
    const std = @import("std");
    std.debug.print("Hello, world: {d}!\n", .{ext2.ext2_pub_fn(1)});
    _ = ext2;
    myRefAllDecls(@This());
    @import("std").testing.refAllDecls(@This());
}
