const builtin = @import("builtin");
const std = @import("std");
const InterruptPool = @import("commons/int.zig").InterruptPool;

const log = std.log.scoped(.int);
const Int = @This();

pub usingnamespace switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/int.zig"),
    else => |other| @compileError("Unimplemented for " ++ @tagName(other)),
};

var pool: InterruptPool = .{};

pub fn processISRList(vec_no: Int.VectorIndex) !void {
    if (isr_map) |map| {
        if (map.get(vec_no)) |lst| {
            for (lst.items) |handler| {
                try handler.func(handler.ctx);
            }
        }
    }
}

pub const ISR = *const fn (ctx: ?*anyopaque) Int.ISRError!void;

pub const ISRHandler = struct {
    unique_id: u32, //unique id for the handler
    ctx: ?*anyopaque, //func-tion argument - store it on heap
    func: ISR,
};

const ISRHandlerList = std.AutoArrayHashMap(Int.VectorIndex, *std.ArrayList(*const ISRHandler));
var isr_map: ?ISRHandlerList = null;
var isr_alloc: std.mem.Allocator = undefined;

pub fn initISRMap(allocator: std.mem.Allocator) void {
    isr_alloc = allocator;
    isr_map = ISRHandlerList.init(isr_alloc);
}

pub fn deinitISRMap() void {
    if (isr_map == null) return;

    // we use arena so we need to free the memory once
    isr_map.deinit();
}

pub fn addISR(vec_no: Int.VectorIndex, isr_handler: *const ISRHandler) !void {
    if (isr_map == null) {
        @panic("Interrupts ISR Handler List not initialized");
    }

    var map = &isr_map.?;

    if (map.get(vec_no)) |lst_ptr| {
        try lst_ptr.append(isr_handler);
    } else {
        const new_lst_ptr = try isr_alloc.create(std.ArrayList(*const ISRHandler));
        new_lst_ptr.* = std.ArrayList(*const ISRHandler).init(isr_alloc);

        try new_lst_ptr.append(isr_handler);
        try map.put(vec_no, new_lst_ptr);
    }

    log.warn("Interrupt ISR Handller added for vector_no: 0x{x}; isr_map len: {d}", .{ vec_no, map.count() });
}

pub fn bindSampleISR(comptime vec_no: Int.VectorIndex) ISR {
    return struct {
        fn handle() Int.ISRError!void {
            log.warn("ISR Handler called for vector_no: 0x{x}", .{vec_no});
        }
    }.handle;
}

// Default Interrupt Pool used by arch specific code (init function)
pub fn defaultPool() *InterruptPool {
    return &pool;
}
