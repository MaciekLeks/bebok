const std = @import("std");

const BlockDevice = @import("devices").BlockDevice;
const Guid = @import("commons").Guid;
const Partition = @import("devices").Partition;

//TODO: add code to read GPT header and entries from the mirror

pub const GptError = error{
    InvalidSignature,
    InvalidRevision,
    InvalidHeaderSize,
    InvalidHeaderCrc32,
    InvalidPartitionEntrySize,
    InvalidPartitionArrayCrc32,
};

pub const GptHeader = extern struct {
    signature: [8]u8 align(1), // Must be "EFI PART" (0x5452415020494645)
    revision: u32 align(1), // For version 1.0, must be 0x00010000
    header_size: u32 align(1), // Must be 92 (0x5C)
    header_crc32: u32 align(1), // CRC32 of header with this field zeroed
    reserved: u32 align(1), // Must be zero
    self_lba: u64 align(1), // Location of this header copy
    alternate_lba: u64 align(1), // Location of the other header copy
    first_usable_lba: u64 align(1),
    last_usable_lba: u64 align(1),
    disk_guid: Guid align(1),
    partition_entry_lba: u64 align(1),
    number_of_partition_entries: u32 align(1),
    size_of_partition_entry: u32 align(1), // Must be 128 (0x80)
    partition_entry_array_crc32: u32 align(1), // CRC32 of partition entries

    pub fn validate(self: *const GptHeader) GptError!void {
        // Check signature "EFI PART"
        const expected_signature = [_]u8{ 0x45, 0x46, 0x49, 0x20, 0x50, 0x41, 0x52, 0x54 };
        if (!std.mem.eql(u8, &self.signature, &expected_signature)) {
            return GptError.InvalidSignature;
        }

        // Check revision (1.0)
        if (self.revision != 0x00010000) {
            return GptError.InvalidRevision;
        }

        // Check header size
        if (self.header_size != 92) {
            return GptError.InvalidHeaderSize;
        }

        // Check partition entry size
        if (self.size_of_partition_entry != 128) {
            return GptError.InvalidPartitionEntrySize;
        }

        // TODO: Add CRC32 validation
        // Note: CRC32 validation requires copying the header,
        // zeroing the CRC32 field, and then calculating
    }
};

pub const GptPartitionAttributes = packed struct {
    required_to_function: bool,
    reserved: u31,
    type_guid_specific: u32,
};

pub const GptEntry = extern struct {
    partition_type_guid: Guid align(1),
    unique_partition_guid: Guid align(1),
    starting_lba: u64 align(1),
    ending_lba: u64 align(1),
    attributes: GptPartitionAttributes align(1),
    partition_name: [72]u8 align(1), // 36 UTF-16LE characters

    pub fn isEmpty(self: *const GptEntry) bool {
        const zero_guid = std.mem.zeroes(Guid);
        return std.mem.eql(u8, std.mem.asBytes(&self.partition_type_guid), std.mem.asBytes(&zero_guid));
    }

    pub fn getName(self: *const GptEntry) !struct { [72]u8, u8 } {
        var name_buffer: [36]u16 = undefined;
        const utf16_bytes = std.mem.bytesAsSlice(u8, &self.partition_name);

        std.mem.copyForwards(u8, @as([*]u8, @ptrCast(&name_buffer))[0..72], utf16_bytes);

        // Find name length (till null terminator)
        var len: usize = 0;
        while (len < name_buffer.len and name_buffer[len] != 0) : (len += 1) {}

        // Convert UTF-16LE to UTF-8
        var result: [72]u8 = undefined;
        _ = try std.unicode.utf16LeToUtf8(&result, name_buffer[0..len]);

        return .{ result, @intCast(len) };
    }

    pub fn asPartitionEntry(self: *const GptEntry) !Partition.Entry {
        const name_len = try self.getName();
        return Partition.Entry{
            .start_lba = self.starting_lba,
            .end_lba = self.ending_lba,
            .partition_type = try Partition.Type.fromGuid(self.partition_type_guid),
            .attributes = .{
                .required_to_function = self.attributes.required_to_function,
                .type_guid_specific = self.attributes.type_guid_specific,
            },
            .name = name_len[0],
            .name_len = name_len[1],
        };
    }
};

pub const Gpt = struct {
    const Self = @This();

    alloctr: std.mem.Allocator,
    header: GptHeader,
    entries: []GptEntry,

    // Constructor
    // @allocator: Memory allocator
    // @streamer: Block device streamer
    // @lbads: Logical block size in bytes
    pub fn init(allocator: std.mem.Allocator, streamer: BlockDevice.Streamer, lbads: u64) !*const Self {
        // Read GPT Header (LBA1)
        const header_buffer = try allocator.alloc(u8, lbads);
        defer allocator.free(header_buffer);

        var stream = BlockDevice.Stream(u8).init(streamer);
        stream.seek(lbads, .start);

        _ = try stream.readAll(header_buffer);

        const header = @as(*const GptHeader, @ptrCast(header_buffer)).*;
        try header.validate();

        // Read GPT Entries
        const entries_size = header.number_of_partition_entries * header.size_of_partition_entry;
        const entries_buffer = try allocator.alloc(u8, entries_size);
        defer allocator.free(entries_buffer);

        // Seek to partition entries
        stream.seek(header.partition_entry_lba * lbads, .start);
        _ = try stream.readAll(entries_buffer);

        // Convert buffer to entries
        const entries = try allocator.alloc(GptEntry, header.number_of_partition_entries);
        const entries_ptr = @as([*]const GptEntry, @ptrCast(entries_buffer.ptr));
        @memcpy(entries, entries_ptr[0..header.number_of_partition_entries]);

        const self = try allocator.create(Self);
        self.alloctr = allocator;
        self.header = header;
        self.entries = entries;

        return self;
    }

    pub fn deinit(self: *const Self) void {
        self.alloctr.free(self.entries);
    }

    // Helper methods
    pub fn getPartitionCount(self: *const Self) u32 {
        var count: u32 = 0;
        for (self.entries) |entry| {
            if (!entry.isEmpty()) {
                count += 1;
            }
        }
        return count;
    }

    pub fn getPartitionEntryAt(self: *const Self, index: usize) !?Partition.Entry {
        const count = self.getPartitionCount();
        if (index >= count) return null;

        // Znajdź n-tą niepustą partycję
        var current_index: usize = 0;
        var found_index: usize = 0;

        while (current_index < count) : (current_index += 1) {
            const entry = &self.entries[current_index];
            if (!entry.isEmpty()) {
                if (found_index == index) {
                    return try entry.asPartitionEntry();
                }
                found_index += 1;
            }
        }
        return null;
    }
};

test "GPT Header validation" {
    const testing = std.testing;

    // Prepare valid GPT Header
    var header = std.mem.zeroes(GptHeader);
    header.signature = .{ 0x45, 0x46, 0x49, 0x20, 0x50, 0x41, 0x52, 0x54 }; // "EFI PART"
    header.revision = 0x00010000;
    header.header_size = 92;
    header.size_of_partition_entry = 128;

    // Test valid header - poprawione wywołanie
    try header.validate();

    // Test invalid signature
    var invalid_header = header;
    invalid_header.signature = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    try testing.expectError(GptError.InvalidSignature, invalid_header.validate());

    // Test invalid revision
    invalid_header = header;
    invalid_header.revision = 0x00020000;
    try testing.expectError(GptError.InvalidRevision, invalid_header.validate());
}

test "GPT Entry" {
    const testing = std.testing;

    var entry = std.mem.zeroes(GptEntry);

    // Test empty entry
    try testing.expect(entry.isEmpty());

    // Test non-empty entry
    entry.partition_type_guid.data1 = 0x12345678;
    try testing.expect(!entry.isEmpty());

    // Test partition name
    entry.partition_name = std.mem.zeroes([72]u8);
    const name = [_]u16{ 'T', 'e', 's', 't', 0 };
    @memcpy(@as([*]u8, @ptrCast(&entry.partition_name))[0..10], std.mem.sliceAsBytes(&name));

    const retrieved_name = entry.getName();
    try testing.expectEqualSlices(u16, &name, retrieved_name);
}
