alloctr: std.mem.Allocator, //Priv for internal struct usage
pid: Pid = .unassigned, // Process ID
parent: ?*Task = null, // Parent task, null if no parent

fds: FDTable = .{},
ctx: Context = .{},

children: ListHead = undefined, // Head of the children list
sibling_node: ListHead = undefined, // A node in the parent's children list
global_node: ListHead = undefined, // A node in the global task list

pub fn new(allocator: std.mem.Allocator) !*Task {
    const self = try allocator.create(Task);

    self.* = .{
        .alloctr = allocator,
        .pid = try pidtracker.getNextPid(),
        .parent = null,
        .fds = .{}, //TODO
        .ctx = .{}, //TODO
        .children = ListHead.init(),
        .sibling_node = ListHead.init(),
        .global_node = ListHead.init(),
    };

    return self;
}

pub fn destroy(self: *const Task) void {
    pidtracker.releasePid(self.pid);
    self.alloctr.destroy(self);
}

// Self reference
const Task = @This();

//Imports
const std = @import("std");
const FDTable = @import("fs").FDTable;
const Context = @import("core").Context;
const paging = @import("core").paging;
const pidtracker = @import("pidtracker.zig");
const Pid = pidtracker.Pid;
const ListHead = @import("commons").ListHead;
