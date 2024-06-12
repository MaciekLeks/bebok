const limine = @import("limine");
const std = @import("std");
const paging = @import("paging.zig");
const gdt = @import("gdt.zig");
const idt = @import("int.zig");
const cpu = @import("cpu.zig");

const log = std.log.scoped(.start);

// Set the base revision to 1, this is recommended as this is the latest
// base revision described by the Limine boot protocol specification.
// See specification for further info.
pub export var base_revision: limine.BaseRevision = .{ .revision = 1 };
pub export var terminal_request: limine.TerminalRequest = .{};

pub inline fn done() noreturn {
    cpu.halt();
}

pub fn init() !void {
    // Ensure the bootloader actually understands our base revision (see spec).
    if (!base_revision.is_supported()) {
        done(); //TODO remove it from here
    }

    cpu.cli();
    gdt.init();
    idt.init();
    cpu.sti();

    try paging.init();
}
