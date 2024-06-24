const builtin = @import("builtin");
const std = @import("std");

const log = std.log.scoped(.int);
const Int = @This();

pub usingnamespace switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/int.zig"),
    else => |other| @compileError("Unimplemented for " ++ @tagName(other)),
};

pub  fn ISRHandleLoop(vec_no: Int.VectorIndex) !void {
    if (isr_map) |map| {
        if (map.get(vec_no)) |lst| {
            for (lst.items) |handler| {
                try handler.handle_fn();
            }
        }
    }
}

//{ ISR handlers
pub const ISRHandler = struct {
    unique_id: u32, //unique id for the handler
    handle_fn: *const fn () Int.ISRError!void,
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

pub fn addHandler(vec_no: Int.VectorIndex, isr_handler: ISRHandler) !void {
    if (isr_map == null) @panic("Interrupts ISR Handler List not initialized");

    if (isr_map.?.get(vec_no)) |lst_ptr| {
        lst_ptr.append(isr_handler) catch |err| {
            log.err("Interrupts ISR Handler List error", .{});
            return err;
        };
    } else {
        const new_list_ptr = try isr_alloc.create(std.ArrayList(ISRHandler));
        new_list_ptr.* = std.ArrayList(ISRHandler).init(isr_alloc);

        isr_map.?.put(vec_no, new_list_ptr) catch |err| {
            log.err("Interrupts ISR Handler List error", .{});
            return err;
        };
    }
}

//} ISR handlers