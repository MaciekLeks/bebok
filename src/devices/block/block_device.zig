pub const BlockDevice = union(enum) {
    nvme: NvmeController,
};
