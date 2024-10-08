const std = @import("std");
const builtin = @import("builtin");
const limine = @import("limine");
const config = @import("config");
const cpu = @import("cpu.zig");
//const start = @import("start.zig");
const segmentation = @import("segmentation.zig");
const paging = @import("paging.zig");
const pmm = @import("mem/pmm.zig");
const heap = @import("mem/heap.zig").heap;
const term = @import("terminal");
const pcie = @import("drivers/pcie.zig");
const Nvme = @import("drivers/Nvme.zig");
const int = @import("int.zig");
const smp = @import("smp.zig");
const acpi = @import("acpi.zig");

const log = std.log.scoped(.kernel);

pub export var base_revision: limine.BaseRevision = .{ .revision = 1 };

pub const std_options = .{
    .logFn = logFn,
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .bbtree, .level = .info },
    },
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
        cpu.putb(char);
        if (char == '\n') {
            for (0..prefix.len - 10) |_| cpu.putb(' ');
            cpu.putb('|');
            cpu.putb(' ');
        }
    }

    cpu.putb('\n');
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @setCold(true);

    log.err("{s}", .{msg});

    cpu.halt();
}

export fn _start() callconv(.C) noreturn {
    // Ensure the bootloader actually understands our base revision (see spec).
    if (!base_revision.is_supported()) {
        cpu.halt();
    }

    smp.init();

    cpu.cli();
    segmentation.init();

    paging.init() catch |err| {
        log.err("Paging initialization error: {}", .{err});
        @panic("Paging initialization error");
    };

    // acpi.init() catch |err| {
    //     log.err("ACPI initialization error: {}", .{err});
    //     @panic("ACPI initialization error");
    // };

    pmm.init() catch |err| {
        log.err("PMM initialization error: {}", .{err});
        @panic("PMM initialization error");
    };
    defer pmm.deinit(); //TODO not here

    const allocator = heap.page_allocator;
    const memory = allocator.alloc(u8, 0x3000) catch |err| {
        log.err("OOM: {}", .{err});
        @panic("OOM");
    };
    log.warn("Allocated memory at {*}", .{memory});
    allocator.free(memory);

    //{  init handler list
    int.init(int.processISRList);
    var arena_allocator = std.heap.ArenaAllocator.init(heap.page_allocator);
    int.initISRMap(arena_allocator.allocator());
    defer int.deinitISRMap();

    int.addISR(0x30, .{ .unique_id = 0x01, .func = &testISR2 }) catch |err| {
        log.err("Failed to add Timer interrupt handler: {}", .{err});
    };
    int.addISR(0x31, .{ .unique_id = 0x02, .func = &testISR2 }) catch |err| {
        log.err("Failed to add NVMe interrupt handler: {}", .{err});
    };

    cpu.sti();
    //} init handler list

    //pci test start
    pcie.init();
    Nvme.init();
    pcie.scan() catch |err| {
        log.err("PCI scan error: {}", .{err});
        @panic("PCI scan error");
    };
    defer Nvme.deinit();
    defer pcie.deinit(); //TODO: na pewno?
    //pci test end

    var pty = term.GenericTerminal(term.FontPsf1Lat2Vga16).init(255, 0, 0, 255) catch @panic("cannot initialize terminal");
    pty.printf("Bebok version: {any}\n", .{config.kernel_version});

    //start.done(); //only now we can hlt - do not use defer after start.init();
    cpu.halt();
}

//TODO tbd
fn testISR2() !void {
    log.warn("apic: 2----->>>>!!!!", .{});
}
