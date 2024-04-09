//const builtin = @import("builtin");
//const console = @import("terminal/console.zig");
//const mm = @import("memory/mmap.zig");
//const Heap = @import("memory/heap/heap.zig").Heap;
//const com = @import("common/common.zig");
const limine = @import("limine");
const com = @import("common/common.zig");
const std = @import("std");

const term = @import("terminal");
//export means that linker can see this function

// Set the base revision to 1, this is recommended as this is the latest
// base revision described by the Limine boot protocol specification.
// See specification for further info.
pub export var base_revision: limine.BaseRevision = .{ .revision = 1 };

inline fn done() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

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

// The following will be our kernel's entry point.
export fn _start() callconv(.C) noreturn {
    // Ensure the bootloader actually understands our base revision (see spec).
    if (!base_revision.is_supported()) {
        done();
    }


    //var term = console.buildTerminal(psf.buildFont("lat2-08.psf")).init(console.ConsoleColors.Cyan, console.ConsoleColors.DarkGray);
    //var term = console.GenericTerminal(console.FontPsf1Koi8x14).init(255, 255, 0, 255);
   var pty = term.GenericTerminal(term.FontPsf1Lat2Vga16).init(255, 0, 0, 255) catch com.panic();
   //var term = console.GenericTerminal(console.FontPsf2Tamsyn8x16r).init(255, 0, 0, 255);

    pty.printf("kotą i ścierę {s}\n", .{"pies"} );

    if (terminal_request.response) |terminal_response| {
            pty.printf("Response: {d}\n", .{terminal_response.terminal_count});
        } else {
            pty.printf("No response\n", .{});
        }

    // We're done, just hang...
    done();
}
