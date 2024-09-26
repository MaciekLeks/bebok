const NvmeDevice = @import("nvme/nvme_device.zig").NvmeDevice;

pub const BlockDevice = union(enum) {
    nvme: NvmeDevice,
};
