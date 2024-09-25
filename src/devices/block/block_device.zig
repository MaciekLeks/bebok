const NvmeDevice = @import("nvme/nvme.zig").NvmeDevice;

pub const BlockDevice = union(enum) {
    nvme: NvmeDevice,
};
