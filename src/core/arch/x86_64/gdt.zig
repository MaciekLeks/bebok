const std = @import("std");
const cpu = @import("./cpu.zig");
const dpl = @import("./dpl.zig");
const Tss = @import("./Tss.zig");

const log = std.log.scoped(.gdt);

const Flags = packed struct(u4) {
    reserved: u1 = 0, //Reserved
    long_mode_code: bool, //Reserved
    db: SegmentMode, //Size bit must be cleared for long_mode
    granularity: GranularityType, //Granularity bit

    const SegmentMode = enum(u1) {
        default = 0, //clear for long_mode
        x32 = 1,
    };

    /// Granularity bit how to treat the limit field
    const GranularityType = enum(u1) {
        byte = 0,
        page = 1,
    };
};

const DescriptorType = enum(u1) {
    system = 0,
    code_data = 1,
};

const GdtEntry = packed struct(u64) {
    limit_low: u16, //0-15
    base_low: u24, //16-39
    access: AccessByte, //40-47
    limit_high: u4, //48-51
    flags: Flags, //52-55
    base_high: u8, //56-63

    const AccessByte = packed struct(u8) {
        accessed: bool, //Accessed bit
        readable_writable: ReadableWritable, //Readable bit/Writable bit
        direction_conforming: DirectionConforming, //Direction bit/Conforming bit
        executable: bool, //Executable bit
        dtype: DescriptorType, //Type bit
        privilege: dpl.PrivilegeLevel, //Privilege level
        present: bool = true, //Present bit

        const ReadableWritable = packed union {
            code: enum(u1) { //for code segments
                not_readable = 0,
                readable = 1,
            },
            data: enum(u1) { //for data segments
                not_writable = 0,
                writable = 1,
            },
        };

        const DirectionConforming = packed union {
            data: enum(u1) {
                grows_up = 0, //Data segment grows up
                grows_down = 1, //Data segment grows down
            },
            code: enum(u1) {
                restricted = 0, //If clear (0) code in this segment can only be executed from the ring set in DPL.
                unrestricted = 1, //If set (1) code in this segment can be executed from an equal or lower privilege level. For example, code in ring 3 can far-jump to conforming code in a ring 2 segment.
            },
        };
    };

    pub fn init(base: usize, limit: usize, access: AccessByte, flags: Flags) GdtEntry {
        return .{
            .limit_low = @as(u16, limit & 0xFFFF),
            .base_low = @as(u24, base & 0xFFFFFF),
            .access = access,
            .limit_high = @as(u4, (limit >> 16) & 0xF),
            .flags = flags,
            .base_high = @as(u8, (base >> 24) & 0xFF),
        };
    }
};

const TssGdtEntry = packed struct(u128) {
    limit_low: u16, //0-15
    base_low: u24, //16-39
    access: AccessByte, //40-47
    limit_high: u4, //48-51
    flags: Flags, //52-55
    base_high: u40, //56-95
    rsrvd: u32 = 0, //96-127

    const AccessByte = packed struct(u8) {
        sdtype: SystemDescriptorType, //System Descriptor Type,
        dtype: DescriptorType, //Type bit
        privilege: dpl.PrivilegeLevel, //Privilege level
        present: bool = true, //Present bit

        const ReadableWritable = packed union {
            code: enum(u1) { //for code segments
                not_readable = 0,
                readable = 1,
            },
            data: enum(u1) { //for data segments
                not_writable = 0,
                writable = 1,
            },
        };

        const SystemDescriptorType = enum(u4) {
            ldt = 0x2, //Local Descriptor Table
            tss_available = 0x9, //Available TSS
            tss_busy = 0xB, //Busy TSS
        };
    };

    pub fn init(base: usize, limit: usize, access: AccessByte, flags: Flags) TssGdtEntry {
        return .{
            .limit_low = @truncate(limit),
            .base_low = @truncate(base),
            .access = access,
            .limit_high = @truncate(limit >> 16),
            .flags = flags,
            .base_high = @truncate(base >> 24),
        };
    }
};

pub const Gdtd = packed struct(u80) {
    size: u16, //0-15
    offset: u64, //16-79
};

// src: https://wiki.osdev.org/GDT_Tutorial
var gdt = [_]GdtEntry{
    @bitCast(@as(u64, 0)),
    // Kernel Mode Code Segment - x64
    GdtEntry.init(0, 0, .{
        .accessed = true, //to avoid page fault in interrupts
        .readable_writable = .{ .code = .readable },
        .direction_conforming = .{ .code = .restricted },
        .executable = true,
        .dtype = .code_data,
        .privilege = dpl.PrivilegeLevel.ring0,
        .present = true,
    }, .{
        .long_mode_code = true,
        .db = .default,
        .granularity = .page,
    }),
    // Kernel Mode Data Segment - x64
    GdtEntry.init(0, 0, .{
        .accessed = true, //to avoid page fault in interrupts
        .readable_writable = .{ .data = .writable },
        .direction_conforming = .{ .data = .grows_up },
        .executable = false,
        .dtype = .code_data,
        .privilege = dpl.PrivilegeLevel.ring0,
        .present = true,
    }, .{
        .long_mode_code = false,
        .db = .default,
        .granularity = .page,
    }),
    // User Mode Code Segment - x64
    GdtEntry.init(0, 0, .{
        .accessed = true,
        .readable_writable = .{ .code = .readable },
        .direction_conforming = .{ .code = .restricted },
        .executable = true,
        .dtype = .code_data,
        .privilege = dpl.PrivilegeLevel.ring3,
        .present = true,
    }, .{
        .long_mode_code = true,
        .db = .default,
        .granularity = .page,
    }),
    // User Mode Data Segment - x64
    GdtEntry.init(0, 0, .{
        .accessed = false,
        .readable_writable = .{ .data = .writable },
        .direction_conforming = .{ .data = .grows_up },
        .executable = false,
        .dtype = .code_data,
        .privilege = dpl.PrivilegeLevel.ring0,
        .present = true,
    }, .{
        .long_mode_code = false,
        .db = .default,
        .granularity = .page,
    }),
    @bitCast(@as(u64, 0)), //TODO: only one TSS entry for now (one processor supported))
    @bitCast(@as(u64, 0)), //TODO: only one TSS entry for now (one processor supported))
};

var gdtd: Gdtd = undefined;

pub const segment_selector = enum(u8) {
    kernel_code = 0x08,
    kernel_data = 0x10,
    user_code = 0x18,
    user_data = 0x20,
    tss = 0x28,
};

fn logDebugInfo() void {
    log.debug("GDTD:  size=0x{x}, offset=0x{x}", .{ gdtd.size, gdtd.offset });

    for (gdt, 0..) |entry, i| {
        const a = @as(u8, @bitCast(entry.access));
        const f = @as(u4, @bitCast(entry.flags));
        const entry_as_u64: u64 = @bitCast(entry);
        log.debug("idx: {d} entry=0x{x:0>16} , while access=0x{x}=0b{b:0>8} flags=0x{x}=0b{b:0>8}", .{ i, entry_as_u64, a, a, f, f });
    }
}

pub fn setTss(tss: *const Tss.TaskStateSegment) void {
    log.info("Setting TSS...", .{});
    defer log.info("Setting TSS finished.", .{});

    const tssge = TssGdtEntry.init(
        @intFromPtr(tss),
        @sizeOf(Tss.TaskStateSegment) - 1,
        .{
            .sdtype = .tss_available,
            .dtype = .system,
            .privilege = dpl.PrivilegeLevel.ring3,
            .present = true,
        },
        .{
            .long_mode_code = false,
            .db = .default,
            .granularity = .byte,
        },
    );

    const idx = @intFromEnum(segment_selector.tss) / @sizeOf(GdtEntry);
    const target: *TssGdtEntry = @ptrCast(@alignCast(&gdt[idx]));

    target.* = tssge;

    log.debug("Setting Task Register...", .{});
    cpu.ltr(@intFromEnum(segment_selector.tss));
    log.debug("Setting Task Register finished.", .{});
}

pub fn init() void {
    log.info("Initializing GDT", .{});
    defer log.info("GDT initialized", .{});
    gdtd = .{
        .size = @sizeOf(@TypeOf(gdt)) - 1,
        .offset = @intFromPtr(&gdt),
    };

    logDebugInfo();

    log.info("Loading GDT", .{});

    cpu.lgdt(&gdtd, @intFromEnum(segment_selector.kernel_code), @intFromEnum(segment_selector.kernel_data));

    log.info("GDT loaded", .{});

    // Set the segment registers to the kernel code and data segments
}
