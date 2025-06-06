///! A starting point for task management
const log = std.log.scoped(.sched);

//Variables
var alloctr: std.mem.Allocator = undefined;
var tasks: ListHead = undefined; // The head of the global task list
var curr_task: ?*Task = null; // Current task

pub fn init(allocator: std.mem.Allocator) !void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialized.", .{});

    alloctr = allocator;
    tasks = ListHead.init();
}

pub fn getCurrTask() ?*Task {
    return curr_task;
}

pub fn getCurrPid() Pid {
    return curr_task.pid;
}

pub fn addTask(task: *Task) !Pid {
    tasks.addAfter(&task.global_node);
}

pub fn removeTask(task: *Task) void {
    task.global_node.remove();

    //Remove all children and their descendants
    var current = task.children.next;
    while (current != &task.children) {
        const child: *Task = @fieldParentPtr("sibling_node", current);
        const next = current.next;
        removeTask(child);
        current = next;
    }

    //Now free the task itself
    task.destroy();
}

pub fn iterate() void {
    var current = tasks.next;
    while (current != &tasks) {
        const task: *const Task = @fieldParentPtr("global_node", current);
        std.debug.print("Task {}\n", .{task.pid});
        current = current.next;
    }
}

pub fn nextTask() !*Task {
    if (tasks.isEmpty()) {
        return error.NoTasks;
    }
    return @fieldParentPtr("global_node", curr_task.next);
}

pub fn nextParentTask(parent: *Task) !*Task {
    var current = parent.children.next;
    while (current != &parent.children) {
        const child: *Task = @fieldParentPtr("sibling_node", current);
        current = child.next;
    }
}

/// Add a child task to the parent task's children list
pub fn addChild(parent: *Task, child: *Task) void {
    child.parent = parent;
    parent.children.addAfter(&child.sibling_node);
}

//Imports
const std = @import("std");
const pidtracker = @import("pidtracker.zig");
const Pid = pidtracker.Pid;
const ListHead = @import("commons").ListHead;
const Task = @import("Task.zig");
