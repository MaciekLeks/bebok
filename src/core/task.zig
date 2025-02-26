///! A starting point for task management
const FileDescriptorTable = @import("../fs/types.zig").FileDescriptorTable;

pub const Task = struct {
    fds: FileDescriptorTable,
};
