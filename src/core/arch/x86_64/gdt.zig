const std = @import("std");
const cpu = @import("./cpu.zig");
const dpl = @import("./dpl.zig");

const log = std.log.scoped(.gdt);

const GdtEntry = packed struct(u64) {
    limit_low: u16, //0-15
    base_low: u24, //16-39
    access: AccessType, //40-47
    limit_high: u4, //48-51
    flags: Flags, //52-55
    base_high: u8, //56-63

    const Flags = packed struct(u4) {
        reserved: u1 = 0, //Reserved
        long_mode_code: bool, //Reserved
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

        const DescriptorType = enum(u1) {
            system = 0,
            code_data = 1,
        };
    };

    pub fn init(base: usize, limit: usize, access: AccessType, flags: Flags) GdtEntry {
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

const TssGdtEntry = packed struct(u64) {
    low: GdtEntry,
    high: packed struct(u64) {
        upper_bits: u32, //32:64 bits of the linear address of the TSS
        rsrvd: u32 = 0,
    },

    pub fn init(base: usize, limit: usize, access: GdtEntry.AccessType, flags: GdtEntry.Flags) TssGdtEntry {
        return .{
            .low = GdtEntry.init(base, limit, access, flags),
            .high = .{
                .upper_bits = @as(u32, (base >> 32) & 0xFFFFFFFF),
            },
        };
    }
};

pub const Gdtd = packed struct(u80) {
    size: u16, //0-15
    offset: u64, //16-79
};

// src: https://wiki.osdev.org/GDT_Tutorial
const gdt = [_]GdtEntry{
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
        .present = true,
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
        .accessed = false,
        .readable_writable = { .code = .readable },
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
    GdtEntry.init(0, 0, .{
        .accessed = false,
        .readable_writable = .{ .data = .writable },
        .direction_conforming = .{ .data = .grows_up },
        .executable = false,
        .dtype = .code_data,
        .privilege = dpl.PrivilegeLevel.ring3,
        .present = true,
    }, .{
        .long_mode_code = false,
        .db = .default,
        .granularity = .page,
    }),
    @bitCast(@as(u64, 0)),
    @bitCast(@as(u64, 0)),
};

var gdtd: Gdtd = undefined;

pub const segment_selector = enum(u8) {
    kernel_code = 0x08,
    kernel_data = 0x10,
    user_code = 0x18,
    user_data = 0x20,
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

pub fn init() void {
    log.info("Initializing GDT", .{});
    defer log.info("GDT initialized", .{});
    gdtd = .{
        .size = @sizeOf(@TypeOf(gdt)) - 1,
        .offset = @intFromPtr(&gdt),
    };

    logDebugInfo();

    //load GS segment selector via cpu.rdmsr but

    const gs = cpu.rdmsr(0x0);

    // const kernel_gs_base: usize = cpu.rdmsr(0xc000_0102);
    // const gs_base: usize = cpu.rdmsr(0xc000_0101);
    // const fs_base: usize = cpu.rdmsr(0xc000_0100);
    //
    // log.info("GDT: Base of kernel gs segment: {x},", .{kernel_gs_base});
    // log.info("GDT: Base of gs segment: {x},", .{gs_base});
    // log.info("GDT: Base of fs segment: {x},", .{fs_base});

    cpu.lgdt(&gdtd, @intFromEnum(segment_selector.kernel_code), @intFromEnum(segment_selector.kernel_data));
}
