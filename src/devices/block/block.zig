const NvmeDevice = @import("nvme/NvmeDevice.zig");
const Device = @import("../Device.zig");

pub const BlockDevice = union(enum) {
    nvme: NvmeDevice,

    pub fn deinit(self: BlockDevice) void {
        return switch (self) {
            inline else => |*it| it.deinit(),
        };
    }
};
