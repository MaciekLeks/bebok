const std = @import("std");

const Gpt = @import("../deps.zig").Gpt;
const BlockDevice = @import("../BlockDevice.zig");
const Partition = @import("Partition.zig");

const log = std.log.scoped("partition_scheme");

const PartitionScheme = @This();

alloctr: std.mem.Allocator,
spec: union(enum) { gpt: *const Gpt },

/// Detects the partition scheme of a block device.
/// Returns a PartitionScheme object if successful, or null for paritionless devices.
/// If an error occurs, the error is returned.
pub fn init(allocator: std.mem.Allocator, streamer: BlockDevice.Streamer) !?*const PartitionScheme {
    var buffer: [512]u8 = undefined;
    //const bytes_read = try reader.readAll(&buffer);
    var stream = BlockDevice.Stream(u8).init(streamer, allocator);

    try stream.readAll(&buffer);

    var self = try allocator.create(PartitionScheme);
    self.alloctr = allocator;

    // Check MBR signature
    if (buffer[510] == 0x55 and buffer[511] == 0xAA) {
        // Check if it's a Protective MBR for GPT
        if (buffer[450] == 0xEE) {
            self.spec.gpt = try Gpt.init(allocator, streamer);
            return self;
        }
        return error.SchemeNotSupported;
    }

    // partitionless device
    return null;
}

pub fn deinit(self: *const PartitionScheme) void {
    switch (self.spec) {
        inline else => |scheme| scheme.deinit(),
    }
}

const PartitionIterator = struct {
    scheme: *const PartitionScheme,
    current_index: usize = 0,

    pub fn next(self: *PartitionIterator) !?Partition {
        const result = switch (self.scheme.spec) {
            inline else => |scheme| try scheme.getPartitionAt(self.current_index),
        };

        if (result == null) {
            return null;
        }

        self.current_index += 1;
        return result;
    }
};

pub fn iterator(self: *const PartitionScheme) PartitionIterator {
    return PartitionIterator{
        .scheme = self,
    };
}

pub fn asGpt(self: *const PartitionScheme) ?*const Gpt {
    if (self.spec == .gpt) self.spec else null;
}
