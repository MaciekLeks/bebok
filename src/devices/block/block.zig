const NvmeController = @import("nvme/NvmeController.zig");
const Device = @import("../Device.zig");

pub const BlockDevice = union(enum) {
    nvme: NvmeController,

    pub fn deinit(self: BlockDevice) void {
        return switch (self) {
            inline else => |*it| it.deinit(),
        };
    }
};
