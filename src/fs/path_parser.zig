const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const File = @import("File.zig");

const log = std.log.scoped(.file_system_path_parser);

/// Possible errors that can occur during path operations
pub const PathError = error{
    /// File name exceeds the maximum allowed length
    FileNameToLong,
    /// Path component not found in the filesystem
    NotFound,
    /// Path string is malformed or contains invalid characters
    InvalidPath,
} || Allocator.Error;

pub const PathPartType = enum {
    Directory, // for directories
    Unknown, // for last element (could be file or directory)
};

pub const PathPart = struct {
    part: ?[]const u8,
    next: ?*PathPart,
    part_type: PathPartType,
    is_absolute: bool, // new field to indicate if this is part of absolute path
    allocator: Allocator,

    pub fn init(allocator: Allocator) PathPart {
        return PathPart{
            .part = null,
            .next = null,
            .part_type = .Unknown,
            .is_absolute = false,
            .allocator = allocator,
        };
    }
};

pub fn parse(allocator: Allocator, path: []const u8) PathError!*PathPart {
    const result = try allocator.create(PathPart);
    errdefer allocator.destroy(result);

    // Handle empty path
    if (path.len == 0) {
        result.* = PathPart.init(allocator);
        return result;
    }

    // Handle root path
    if (path.len == 1 and path[0] == '/') {
        result.* = PathPart{
            .part = null,
            .next = null,
            .part_type = .Directory,
            .is_absolute = true,
            .allocator = allocator,
        };
        return result;
    }

    var start: usize = 0;
    const is_absolute = path[0] == '/';

    if (is_absolute) {
        start = 1;
    }

    // Skip empty parts (multiple slashes)
    while (start < path.len and path[start] == '/') : (start += 1) {}
    if (start == path.len) {
        result.* = PathPart{
            .part = null,
            .next = null,
            .part_type = .Directory,
            .is_absolute = is_absolute,
            .allocator = allocator,
        };
        return result;
    }

    // Find next part
    var i = start;
    while (i < path.len and path[i] != '/') : (i += 1) {
        if (i - start > File.max_name_len) return error.FileNameToLong;
    }

    const part_end = i;

    // Skip trailing slashes
    var next_start = i;
    while (next_start < path.len and path[next_start] == '/') : (next_start += 1) {}

    const has_more = next_start < path.len;

    result.* = PathPart{
        .part = path[start..part_end],
        .next = if (has_more) try parse(allocator, path[next_start..]) else null,
        .part_type = if (has_more or next_start > i) .Directory else .Unknown,
        .is_absolute = is_absolute,
        .allocator = allocator,
    };

    return result;
}

test "empty path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parse(allocator, "");
    try testing.expect(result.part == null);
    try testing.expect(result.next == null);
    try testing.expect(result.part_type == .Unknown);
    try testing.expect(!result.is_absolute);
}

test "root path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parse(allocator, "/");
    try testing.expect(result.part == null);
    try testing.expect(result.next == null);
    try testing.expect(result.part_type == .Directory);
    try testing.expect(result.is_absolute);
}

test "absolute path with single element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parse(allocator, "/bin");
    try testing.expectEqualStrings("bin", result.part.?);
    try testing.expect(result.next == null);
    try testing.expect(result.part_type == .Unknown);
    try testing.expect(result.is_absolute);
}

test "absolute path with multiple elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parse(allocator, "/usr/local/bin");
    try testing.expectEqualStrings("usr", result.part.?);
    try testing.expectEqualStrings("local", result.next.?.part.?);
    try testing.expectEqualStrings("bin", result.next.?.next.?.part.?);
    try testing.expect(result.next.?.next.?.next == null);
    try testing.expect(result.part_type == .Directory);
    try testing.expect(result.next.?.part_type == .Directory);
    try testing.expect(result.next.?.next.?.part_type == .Unknown);
    try testing.expect(result.is_absolute);
}

test "relative path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parse(allocator, "local/bin");
    try testing.expectEqualStrings("local", result.part.?);
    try testing.expectEqualStrings("bin", result.next.?.part.?);
    try testing.expect(result.next.?.next == null);
    try testing.expect(result.part_type == .Directory);
    try testing.expect(result.next.?.part_type == .Unknown);
    try testing.expect(!result.is_absolute);
}

test "path with trailing slash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parse(allocator, "/usr/bin/");
    try testing.expectEqualStrings("usr", result.part.?);
    try testing.expectEqualStrings("bin", result.next.?.part.?);
    try testing.expect(result.next.?.next == null);
    try testing.expect(result.part_type == .Directory);
    try testing.expect(result.next.?.part_type == .Directory);
    try testing.expect(result.is_absolute);
    try testing.expect(!result.next.?.is_absolute); //why absolute?
}

test "path with double slash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parse(allocator, "/usr//bin");
    try testing.expectEqualStrings("usr", result.part.?);
    try testing.expectEqualStrings("bin", result.next.?.part.?);
    try testing.expect(result.next.?.next == null);
    try testing.expect(result.part_type == .Directory);
    try testing.expect(result.next.?.part_type == .Unknown);
    try testing.expect(result.is_absolute);
}
