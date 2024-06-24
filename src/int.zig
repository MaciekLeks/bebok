const builtin = @import("builtin");
const std = @import("std");

const log = std.log.scoped(.int);
const Int = @This();

pub usingnamespace switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/int.zig"),
    else => |other| @compileError("Unimplemented for " ++ @tagName(other)),
};

pub fn ISRHandleLoop(vec_no: Int.VectorIndex) !void {
    if (isr_map) |map| {
        if (map.get(vec_no)) |lst| {
            for (lst.items) |handler| {
                try handler.func();
            }
        }
    }
}

pub const ISR = *const fn () Int.ISRError!void;

//{ ISR handlers
pub const ISRHandler = struct {
    unique_id: u32, //unique id for the handler
    func: ISR,
};

const ISRHandlerList = std.AutoArrayHashMap(Int.VectorIndex, *std.ArrayList(ISRHandler));
var isr_map: ?ISRHandlerList = null;
var isr_alloc: std.mem.Allocator = undefined;

pub fn initHandlerList(allocator: std.mem.Allocator) void {
    isr_alloc = allocator;
    isr_map = ISRHandlerList.init(isr_alloc);
}

pub fn deinitHandlerList() void {
    if (isr_map == null) return;

    // we use arena so we need to free the memory once
    isr_map.deinit();
}

// pub fn addHandler(vec_no: Int.VectorIndex, isr_handler: ISRHandler) !void {
//     if (isr_map == null) @panic("Interrupts ISR Handler List not initialized");
//
//     if (isr_map.?.get(vec_no)) |lst_ptr| {
//         lst_ptr.append(isr_handler) catch |err| {
//             log.err("Interrupts ISR Handler List error", .{});
//             return err;
//         };
//     } else {
//         const new_lst_ptr = try isr_alloc.create(std.ArrayList(ISRHandler));
//         new_lst_ptr.* = std.ArrayList(ISRHandler).init(isr_alloc);
//
//         new_lst_ptr.append(isr_handler) catch |err| {
//             log.err("Interrupts ISR Handler List error", .{});
//             return err;
//         };
//
//         isr_map.?.put(vec_no, new_lst_ptr) catch |err| {
//             log.err("Interrupts ISR Handler List error", .{});
//             return err;
//         };
//     }
//     log.warn("Interrupt ISR Handller added for vector_no: 0x{x}; isr_map len: {d}", .{ vec_no, isr_map.?.count() });
// }
//

pub fn addHandler(vec_no: Int.VectorIndex, isr_handler: ISRHandler) !void {
    if (isr_map == null) {
        @panic("Interrupts ISR Handler List not initialized");
    }

    var map = &isr_map.?;

    // W każdym przypadku, w którym może wystąpić wyjątek, używam operatora 'try',
    // który automatycznie przekazuje wyjątek do wywołującego funkcję.
    if (map.get(vec_no)) |lst_ptr| {
        try lst_ptr.append(isr_handler);
    } else {
        const new_lst_ptr = try isr_alloc.create(std.ArrayList(ISRHandler));
        new_lst_ptr.* = std.ArrayList(ISRHandler).init(isr_alloc);

        try new_lst_ptr.append(isr_handler);
        try map.put(vec_no, new_lst_ptr);
    }

    log.warn("Interrupt ISR Handller added for vector_no: 0x{x}; isr_map len: {d}", .{ vec_no, map.count() });
}
//} ISR handlers
