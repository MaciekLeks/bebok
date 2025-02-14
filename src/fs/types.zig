const std = @import("std");

pub const InodeNum = u32;

pub const FilesystemType = enum {
    ext2,
    unknown,
};

pub const Superblock = struct {
    pub const VTable = struct {
        deinit: *const fn (ctx: *anyopaque) void,
        readInode: *const fn (ctx: *anyopaque, inode_num: InodeNum) anyerror!*anyopaque,
    };

    //Regular Fields
    alloctr: std.mem.Allocator,
    ptr: *anyopaque,
    vtable: VTable,
    //VFS Superblock Fields
    block_size: u16,

    pub fn init(allocator: std.mem.Allocator, ptr: *anyopaque, vtable: VTable) !*Superblock {
        const sb = try allocator.create(Superblock);
        sb.* = .{
            .alloctr = allocator,
            .ptr = ptr,
            .vtable = vtable,
        };
        return sb;
    }

    pub fn deinit(self: *Superblock) void {
        defer self.alloctr.destroy(self);
    }

    pub fn readInode(sb: *const Superblock, inode_num: InodeNum) !*const Inode {
        _ = sb;
        _ = inode_num;
        return error.NotImplemented;
    }
};

pub const Inode = struct {
    pub const VTable = struct {
        deinit: *const fn (ctx: *anyopaque) void,
    };

    //Regular Fields
    alloctr: std.mem.Allocator,
    ptr: *anyopaque,
    vtable: VTable,
    //VFS Inode Fields
    inode_num: InodeNum,

    pub fn init(allocator: std.mem.Allocator, ptr: *anyopaque, vtable: VTable) !*Superblock {
        const sb = try allocator.create(Superblock);
        sb.* = .{
            .alloctr = allocator,
            .ptr = ptr,
            .vtable = vtable,
        };
        return sb;
    }

    pub fn deinit(self: *Superblock) void {
        defer self.alloctr.destroy(self);
    }
};

pub const FD = struct {
    file: *const File,
};

pub const File = struct {
    pub const Error = error{
        NotFound,
    };
    pub const max_name_len = 256;

    dentry: *const DEntry,
};

pub const DEntry = struct {
    parent: *const DEntry,
};
