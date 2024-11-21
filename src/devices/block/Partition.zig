const std = @import("std");

const Guid = @import("../deps.zig").Guid;

const log = std.log.scoped("partition");

const Partition = @This();

pub const Type = enum {
    efi_system,
    linux_filesystem,
    linux_swap,
    msft_basic_data,
    unknown,

    const GuidMapping = struct {
        guid: Guid,
        type: Type,
    };

    pub fn fromGuid(guid: Guid) !Type {
        // Statyczna lista mapowań GUID -> Type
        const guid_mappings = [_]GuidMapping{
            .{
                // EFI System Partition
                .guid = Guid{
                    .data1 = 0xC12A7328,
                    .data2 = 0xF81F,
                    .data3 = 0x11D2,
                    .data4 = .{ 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B },
                },
                .type = Type.efi_system,
            },
            .{
                // Linux Filesystem
                .guid = Guid{
                    .data1 = 0x0FC63DAF,
                    .data2 = 0x8483,
                    .data3 = 0x4772,
                    .data4 = .{ 0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4 },
                },
                .type = Type.linux_filesystem,
            },
            .{
                // Linux Swap
                .guid = Guid{
                    .data1 = 0x0657FD6D,
                    .data2 = 0xA4AB,
                    .data3 = 0x43C4,
                    .data4 = .{ 0x84, 0xE5, 0x09, 0x33, 0xC8, 0x4B, 0x4F, 0x4F },
                },
                .type = Type.linux_swap,
            },
            .{
                // Microsoft Basic Data
                .guid = Guid{
                    .data1 = 0xEBD0A0A2,
                    .data2 = 0xB9E5,
                    .data3 = 0x4433,
                    .data4 = .{ 0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7 },
                },
                .type = Type.msft_basic_data,
            },
        };

        // Iteracja po mapowaniach w runtime
        for (guid_mappings) |mapping| {
            if (std.mem.eql(u8, std.mem.asBytes(&guid), std.mem.asBytes(&mapping.guid))) {
                return mapping.type;
            }
        }

        return .unknown;
    }
};

pub const Attributes = struct {
    required_to_function: bool,
    type_guid_specific: u32,
};

//Fields
start_lba: u64,
end_lba: u64,
partition_type: Type,
attributes: Attributes,
name: [72]u8, //max as for GPT

pub fn getSize(self: *const Partition) u64 {
    return (self.end_lba - self.start_lba + 1) * 512;
}
