//const builtin = @import("builtin");
//const console = @import("terminal/console.zig");
//const mm = @import("memory/mmap.zig");
//const Heap = @import("memory/heap/heap.zig").Heap;
//const com = @import("common/common.zig");
const limine = @import("limine");
//const com = @import("common/common.zig");
const std = @import("std");


const paging = @import("paging.zig");
const gdt = @import("gdt.zig");
const assm = @import("asm.zig");
//const heap = @import("memory/heap.zig");
//export means that linker can see this function

// Set the base revision to 1, this is recommended as this is the latest
// base revision described by the Limine boot protocol specification.
// See specification for further info.
pub export var base_revision: limine.BaseRevision = .{ .revision = 1 };

//var str = "\n- long-mode, \n- paging for 2MB, \n- sys memory map.";
// export fn _start() callconv(.C) noreturn {
//     // const color_ptr = &term.color;
//     // color_ptr.* = 0x0f;
//     pty.initialize(pty.ConsoleColors.Cyan, pty.ConsoleColors.DarkGray);
//     pty.puts("I'm real Borok OS\n");
//     // pty.printf("My message to you: {s}", .{str});
//
//     // Get system momory map and check if some address is availiable to use
//     // const smap =  mm.SysMemMap.init();
//     // const v_addr = 0x100_0000;
//     // const v_len = 0x1000;
//     // const is_free = smap.isFree(v_addr, v_len);
//     // if (is_free) {
//     //     pty.puts("\n0x100_0000 mem is free!\n");
//     // } else {
//     //     pty.puts("\n0x100_0000 mem is not free!\n");
//     // }
//
//     //only 4KB - not finished
//     // const heap = Heap.init(com.OS_HEAP_ADDRESS ,com.OS_HEAP_TABLE_ADDRESS, 0x100) catch  {
//     //     pty.puts("Heap init error\n");
//     // };
//     // _ = heap;
//     while (true) {}
// }

pub export var terminal_request: limine.TerminalRequest = .{};

//pub export var memory_map_request: limine.MemoryMapRequest = .{};
//pub export var efi_memory_map_request: limine.EfiMemoryMapRequest = .{};

// src: https://ziglang.org/documentation/master/std/#std.log
// pub const std_options = .{
//     // Define logFn to override the std implementation
//     .logFn = kLogFn,
// };

//
// pub fn kLogFn(comptime message_level: std.log.Level, comptime scope: @Type(.EnumLiteral), comptime format: []const u8, args: anytype) void {
//     var log_allocator_buf: [4096 * 8]u8 = undefined;
//     var log_fba = std.heap.FixedBufferAllocator.init(&log_allocator_buf);
//     const log_allocator = log_fba.allocator();
//
//     const prefix = switch (message_level) {
//     .info => "\x1b[34m",
//     .warn => "\x1b[33m",
//     .err => "\x1b[31m",
//     .debug => "\x1b[90m",
//     } ++ "[" ++ @tagName(message_level) ++ "]\x1b[0m (" ++ @tagName(scope) ++ ")";
//
//     const msg = std.fmt.allocPrint(log_allocator, prefix ++ " " ++ format, args) catch "\x1b[31m\x1b[1m!!!LOG_FN_OOM!!!\x1b[0m";
//
//     pty.printf(msg, .{});
// }
//

const log = std.log.scoped(.start);

pub inline fn done() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

// The following will be our kernel's entry point.
//export fn start() callconv(.C) noreturn
//
pub fn init() void {
    // Ensure the bootloader actually understands our base revision (see spec).
    if (!base_revision.is_supported()) {
        done(); //TODO remove it from here
    }

    assm.cli();
    gdt.init();


    //const log = std.log.scoped(.paging);
    paging.init();
}
