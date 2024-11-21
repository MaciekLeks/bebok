const std = @import("std");

const log = std.log.scoped(.gpt);

pub const ProtectiveMbrError = error{
    InvalidSignature,
    InvalidOsType,
    InvalidStartingLba,
    MultiplePartitions,
    InvalidChs,
};

pub const ProtectiveMbrPartitionEntry = extern struct {
    boot_indicator: u8 align(1),
    starting_chs: [3]u8 align(1),
    os_type: u8 align(1),
    ending_chs: [3]u8 align(1),
    starting_lba: u32 align(1),
    size_in_lba: u32 align(1),

    pub fn validate(self: *const ProtectiveMbrPartitionEntry) ProtectiveMbrError!void {
        if (self.os_type != 0xEE) {
            return ProtectiveMbrError.InvalidOsType;
        }

        if (self.starting_lba != 1) {
            return ProtectiveMbrError.InvalidStartingLba;
        }

        if (self.starting_chs[0] != 0x00 or
            self.starting_chs[1] != 0x02 or
            self.starting_chs[2] != 0x00)
        {
            return ProtectiveMbrError.InvalidChs;
        }
    }
};

pub const ProtectiveMbr = extern struct {
    bootstrap: [440]u8,
    disk_signature: [4]u8,
    reserved: [2]u8,
    partition_entries: [4]ProtectiveMbrPartitionEntry,
    signature: [2]u8,

    pub fn validate(self: *const ProtectiveMbr) ProtectiveMbrError!void {
        // Check MBR signature (0x55AA)
        if (self.signature[0] != 0x55 or self.signature[1] != 0xAA) {
            return ProtectiveMbrError.InvalidSignature;
        }

        // Validate first partition entry
        try self.partition_entries[0].validate();

        // Verify remaining entries are empty
        for (self.partition_entries[1..]) |entry| {
            if (entry.os_type != 0x00 or entry.starting_lba != 0 or entry.size_in_lba != 0) {
                return ProtectiveMbrError.MultiplePartitions;
            }
        }
    }

    // Helper function to check if MBR is a Protective MBR
    pub fn isProtective(self: *const ProtectiveMbr) bool {
        return self.validate() == null;
    }
};

test "Protective MBR validation" {
    const testing = std.testing;

    // Prepare sample valid Protective MBR
    var mbr = std.mem.zeroes(ProtectiveMbr);
    mbr.signature = .{ 0x55, 0xAA };
    mbr.partition_entries[0] = .{
        .boot_indicator = 0x00,
        .starting_chs = .{ 0x00, 0x02, 0x00 },
        .os_type = 0xEE,
        .ending_chs = .{ 0xFF, 0xFF, 0xFF },
        .starting_lba = 1,
        .size_in_lba = 0xFFFFFFFF,
    };

    // Test valid MBR - poprawione wywołanie
    try mbr.validate();

    // Test invalid signature
    var invalid_mbr = mbr;
    invalid_mbr.signature = .{ 0x00, 0x00 };
    try testing.expectError(ProtectiveMbrError.InvalidSignature, invalid_mbr.validate());

    // Test invalid OS type
    invalid_mbr = mbr;
    invalid_mbr.partition_entries[0].os_type = 0x00;
    try testing.expectError(ProtectiveMbrError.InvalidOsType, invalid_mbr.validate());
}
