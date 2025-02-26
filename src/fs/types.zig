const std = @import("std");
const iface = @import("lang").iface;

pub const InodeNum = u32;

pub const FilesystemType = enum {
    ext2,
    unknown,
};

pub const Superblock = struct {
    const Self = @This();
    pub const VTable = struct {
        readInode: iface.Fn(.{ std.mem.Allocator, InodeNum }, anyerror!Inode),
    };

    pub fn init(ctx: anytype) Self {
        return .{
            .ctx = ctx,
            .vtable = iface.gen(@TypeOf(ctx), VTable),
        };
    }

    //Fields
    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn readInode(sb: *const Superblock, inode_num: InodeNum) !*const Inode {
        sb.vtable.readInode(sb.ctx, inode_num);
    }
};

pub const Inode = struct {
    const Self = @This();
    pub const VTable = struct {
        destroy: iface.Fn(.{}, void),
        //create: iface.Fn(.{}, void),
    };

    //Regular Fields
    ctx: *anyopaque,
    vtable: *const VTable,
    //Data Fields
    data: *anyopaque,

    pub fn init(ctx: anytype, data: *anyopaque) Self {
        return .{
            .ctx = ctx,
            .vtable = iface.gen(@TypeOf(ctx), VTable),
            .data = data,
        };
    }

    pub fn deinit(self: *const Self) void {
        self.vtable.destroy(self.ctx);
    }
};

pub const FD = i32;

pub const FileDescriptor = struct {
    pub const Mode = enum {
        rdonly,
        wronly,
        rdwr,
    };

    idx: FD, //FileDescriptorTable idx
    file: *const File,
    mode: Mode,
    pos: usize,
};

pub const FileDescriptorTable = struct {
    const Self = @This();
    const max_fds = 64;

    fds: [max_fds]?*FileDescriptor = .{null} ** max_fds,

    pub fn getNewFileDescriptor(self: *const Self, file: *const File, mode: FileDescriptor.Mode) File.Error!*FileDescriptor {
        for (&self.fds, 0..) |*maybe_fd, i| {
            if (maybe_fd.* == null) {
                maybe_fd.* = FileDescriptor.init(self.alloctr, i, file, mode);
                return maybe_fd;
            }
        }

        return File.Error.MaxFDsReached;
    }

    pub fn deinit(self: *Self) void {
        for (self.fds) |opt_fd| {
            if (opt_fd) |fd| {
                fd.deinit();
            }
        }
    }
};

pub const File = struct {
    pub const Error = error{
        NotFound,
        MaxFDsReached,
    };
    pub const max_name_len = 256;

    //TODO:
    dentry: *const DEntry,
    offset: usize, //file read/write offset
    count: u32, //reference count
};

pub const DEntry = struct {
    parent: *const DEntry,
};
