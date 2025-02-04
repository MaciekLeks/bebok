pub const Device = @import("Device.zig");
pub const BlockDevice = @import("BlockDevice.zig");
pub const PhysDevice = @import("PhysDevice.zig");
pub const PartitionScheme = @import("block/PartitionScheme.zig");
pub const Partition = @import("block/Partition.zig");

//Tests
pub const createMockPartition = @import("block/test/mocks/partition.zig").createMockPartition;
pub const mockDevice = @import("test/mocks/devices.zig").mockDevice;
pub const mockBlockDevice = @import("test/mocks/devices.zig").mockBlockDevice;
