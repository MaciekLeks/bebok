const std = @import("std");
const assm = @import("asm.zig");

const log = std.log.scoped(.gdt);

const GdtEntry = packed struct(u64) {
    limit_a: u16, //0-15
    base_a: u24, //16-39
    access: AccessType, //40-47
    limit_b: u4, //48-51
    flags: Flags, //52-55
    base_b: u8, //56-63

    const Flags = packed struct(u4) {
        reserved: u1 = 0, //Reserved
        long_mode: bool, //Reserved
        db: SegmentMode, //Size bit must be cleared for long_mode
        granularity: GranularityType, //Granularity bit

        const SegmentMode = enum(u1) {
            default = 0, //clear for long_mode and x16 for 16-bit protected mode
            x32 = 1,
        };

        const GranularityType = enum(u1) {
            byte = 0,
            page = 1,
        };
    };

    const AccessType = packed struct(u8) {
        accessed: bool, //Accessed bit
        readable_writable: ReadableWritable, //Readable bit/Writable bit
        direction_conforming: DirectionConforming, //Direction bit/Conforming bit
        executable: bool, //Executable bit
        type: DescriptorType, //Descriptor type bit
        privilege: PrivilegeLevel, //Privilege level
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

        const DescriptorType = enum(u1) {
            system = 0,
            code_data = 1,
        };

        const PrivilegeLevel = enum(u2) {
            ring0 = 0, //kernel
            ring1 = 1,
            ring2 = 2,
            ring3 = 3, //user
        };
    };
};

pub const Gdtd = packed struct(u80) {
    size: u16, //0-15
    offset: u64, //16-79
};

// src: https://wiki.osdev.org/GDT_Tutorial
const gdt = [_]GdtEntry{
    @bitCast(@as(u64, 0)),
    .{ //Kernel Mode Code Segment - x16
        .limit_a = 0xffff,
        .base_a = 0,
        .access = .{
            // equals to 0x9a
            .accessed = false,
            .readable_writable = .{ .code = .readable },
            .direction_conforming = .{ .code = .restricted },
            .executable = true,
            .type = .code_data,
            .privilege = .ring0,
        },
        .limit_b = 0,
        .flags = .{
            // equals to 0xa
            .long_mode = false,
            .db = .default,
            .granularity = .byte,
        },
        .base_b = 0,
    },
    .{
        //Kernel Mode Data Segment - x16
        .limit_a = 0xffff,
        .base_a = 0,
        .access = .{
            // equals to 0x92
            .accessed = false,
            .readable_writable = .{ .data = .writable },
            .direction_conforming = .{ .data = .grows_up },
            .executable = false,
            .type = .code_data,
            .privilege = .ring0,
        },
        .limit_b = 0,
        .flags = .{
            // equals to 0xc
            .long_mode = false,
            .db = .x32,
            .granularity = .byte,
        },
        .base_b = 0,
    },
    .{ //Kernel Mode Code Segment - x32
        .limit_a = 0xffff,
        .base_a = 0,
        .access = .{
            // equals to 0x9a
            .accessed = false,
            .readable_writable = .{ .code = .readable },
            .direction_conforming = .{ .code = .restricted },
            .executable = true,
            .type = .code_data,
            .privilege = .ring0,
        },
        .limit_b = 0xf,
        .flags = .{
            // equals to 0xa
            .long_mode = false,
            .db = .x32,
            .granularity = .page,
        },
        .base_b = 0,
    },
    .{
        //Kernel Mode Data Segment - x32
        .limit_a = 0xffff,
        .base_a = 0,
        .access = .{
            // equals to 0x92
            .accessed = false,
            .readable_writable = .{ .data = .writable },
            .direction_conforming = .{ .data = .grows_up },
            .executable = false,
            .type = .code_data,
            .privilege = .ring0,
        },
        .limit_b = 0xf,
        .flags = .{
            // equals to 0xc
            .long_mode = false,
            .db = .x32,
            .granularity = .page,
        },
        .base_b = 0,
    },
    .{ //Kernel Mode Code Segment - x64
        .limit_a = 0, //irrelevant
        .base_a = 0,
        .access = .{
            // equals to 0x9a
            .accessed = false,
            .readable_writable = .{ .code = .readable },
            .direction_conforming = .{ .code = .restricted },
            .executable = true,
            .type = .code_data,
            .privilege = .ring0,
        },
        .limit_b = 0,
        .flags = .{
            // equals to 0xa
            .long_mode = true,
            .db = .default,
            .granularity = .page,
        },
        .base_b = 0,
    },
    .{
        //Kernel Mode Data Segment - x64
        .limit_a = 0, //irrelevant
        .base_a = 0,
        .access = .{
            // equals to 0x92
            .accessed = true, //to avoid page fault
            .readable_writable = .{ .data = .writable },
            .direction_conforming = .{ .data = .grows_up },
            .executable = false,
            .type = .code_data,
            .privilege = .ring0,
        },
        .limit_b = 0, //irrelevant
        .flags = .{
            // equals to 0xc
            .long_mode = false,
            .db = .x32,
            .granularity = .page,
        },
        .base_b = 0,
    },
    .{
        //User Mode Code Segment
        .limit_a = 0xffff,
        .base_a = 0,
        .access = .{
            // equals to 0xfa
            .accessed = false,
            .readable_writable = .{ .code = .readable },
            .direction_conforming = .{ .code = .restricted },
            .executable = true,
            .type = .code_data,
            .privilege = .ring3,
        },
        .limit_b = 0,
        .flags = .{
            // equals to 0xc
            .long_mode = true,
            .db = .default,
            .granularity = .page,
        },
        .base_b = 0,
    },
    .{
        //User Mode Data Segment
        .limit_a = 0xffff,
        .base_a = 0,
        .access = .{
            // equals to 0xf2
            .accessed = false,
            .readable_writable = .{ .data = .writable },
            .direction_conforming = .{ .data = .grows_up },
            .executable = false,
            .type = .code_data,
            .privilege = .ring3,
        },
        .limit_b = 0,
        .flags = .{
            // equals to 0xc
            .long_mode = false,
            .db = .x32,
            .granularity = .page,
        },
        .base_b = 0,
    },
    //TODO add TSS
};

var gdtd: Gdtd = undefined;

pub const segment_selectors = .{
    .kernel_code_x16 = 0x08,
    .kernel_data_x16 = 0x10,
    .kernel_code_x32 = 0x18,
    .kernel_data_x32 = 0x20,
    .kernel_code_x64 = 0x28,
    .kernel_data_x64 = 0x30,
    .user_code = 0x38,
    .user_data = 0x40,
};

fn selfLogDebug() void {
    log.debug("GDTD:  size=0x{x}, offset=0x{x}", .{ gdtd.size, gdtd.offset });

    for (gdt, 0..) |entry, i| {
        const a = @as(u8, @bitCast(entry.access));
        const f = @as(u4, @bitCast(entry.flags));
        const entry_as_u64: u64 = @bitCast(entry);
        log.debug("idx: {d} entry=0x{x:0>16} , while access=0x{x}=0b{b:0>8} flags=0x{x}=0b{b:0>8}", .{ i, entry_as_u64, a, a, f, f });
    }
    defer log.debug("GDT loaded", .{});
}

pub fn init() void {
    gdtd = .{
        .size = @sizeOf(@TypeOf(gdt)) - 1,
        .offset = @intFromPtr(&gdt),
    };

    selfLogDebug();

    assm.lgdt(&gdtd);
}
