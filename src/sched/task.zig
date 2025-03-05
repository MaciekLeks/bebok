///! A starting point for task management
const FDTable = @import("fs").FDTable;

pub const Task = struct {
    fds: FDTable = .{},
};
