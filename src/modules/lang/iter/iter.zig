const iface = @import("../iface/iface.zig");

pub fn Iterator(comptime RetType: type) type {
    return struct {
        pub const VTable = struct {
            destroy: iface.Fn(.{}, void),
            next: iface.Fn(.{}, anyerror!?RetType),
        };

        //Fields
        ctx: *anyopaque,
        vtable: *const VTable,

        const Self = @This();

        pub fn init(ctx: anytype) Self {
            return .{ .ctx = ctx, .vtable = iface.gen(@TypeOf(ctx), VTable) };
        }

        pub fn next(self: *const Self) !?RetType {
            return self.vtable.next(self.ctx, .{});
        }

        pub fn deinit(self: *const Self) void {
            self.vtable.destroy(self.ctx, .{});
        }
    };
}
