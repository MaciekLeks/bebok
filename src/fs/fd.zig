const File = @import("File.zig");

pub const FD = i32; //POSIX file descriptor

pub const FDTable = struct {
    const Self = @This();
    const max_fds = 64;

    files: [max_fds]?*File = .{null} ** max_fds,

    // Find free file descriptor and assign it to the file
    pub fn getNewFD(self: *Self, file: *File) FD {
        for (&self.files, 0..) |*maybe_file, i| {
            if (maybe_file.* == null) {
                maybe_file.* = file;
                return @intCast(i);
            }
        }

        return -1;
    }

    // Close file descriptor but not free File memory.
    pub fn closeFD(self: *Self, fd: FD) void {
        if (fd >= 0 and fd < max_fds and self.files[fd] != null) {
            self.files[fd].*.decrementRefCount();
            self.files[fd] = null;
        }
    }

    pub fn getFile(self: *const Self, fd: FD) !*File {
        if (fd >= 0 and fd < max_fds and self.files[@intCast(fd)] != null) {
            return self.files[@intCast(fd)].?;
        }
        return File.Error.NotFound;
    }

    pub fn deinit(self: *Self) void {
        for (&self.files) |*maybe_file| {
            if (maybe_file) |file| {
                file.destroy();
            }
        }
    }
};
