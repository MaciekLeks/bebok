const std = @import("std");
const builtin = @import("builtin");
const assm = @import("asm.zig");
const start = @import("start.zig");

const log = std.log.scoped(.kernel);

pub const std_options = .{
    .logFn = logFn,
};

pub fn logFn(comptime message_level: std.log.Level, comptime scope: @Type(.EnumLiteral), comptime format: []const u8, args: anytype) void {
    var log_allocator_buf: [4096 * 8]u8 = undefined;
    var log_fba = std.heap.FixedBufferAllocator.init(&log_allocator_buf);
    const log_allocator = log_fba.allocator();

    const prefix = switch (message_level) {
        .info => "\x1b[34m",
        .warn => "\x1b[33m",
        .err => "\x1b[31m",
        .debug => "\x1b[90m",
    } ++ "[" ++ @tagName(message_level) ++ "]\x1b[0m (" ++ @tagName(scope) ++ ")";

    const msg = std.fmt.allocPrint(log_allocator, prefix ++ " " ++ format, args) catch "\x1b[31m\x1b[1m!!!LOG_FN_OOM!!!\x1b[0m";

    for (msg) |char| {
        assm.putb(char);
        if (char == '\n') {
            for (0..prefix.len - 10) |_| assm.putb(' ');
            assm.putb('|');
            assm.putb(' ');
        }
    }

    assm.putb('\n');
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @setCold(true);

    log.err("{s}", .{msg});

    assm.halt();
}

export fn _start() callconv(.C) noreturn {
    start.init();

    start.done();
}
