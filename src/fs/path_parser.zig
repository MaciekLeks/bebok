const std = @import("std");
const testing = std.testing;

const File = @import("File.zig");

const log = std.log.scoped(.file_system_path_parser);

pub const PathPart = struct {
    part: ?[]const u8,
    next: ?*PathPart,
    alloctr: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PathPart {
        return PathPart{
            .part = null,
            .next = null,
            .alloctr = allocator,
        };
    }

    pub fn deinit(self: *PathPart) void {
        if (self.next) |next| {
            next.deinit();
            self.alloctr.destroy(next);
        }
        self.alloctr.destroy(self);
    }
};

pub fn parse(allocator: std.mem.Allocator, path: []const u8) !*PathPart {
    const result = try allocator.create(PathPart);
    errdefer allocator.destroy(result);

    if (path.len == 0) {
        result.* = PathPart.init(allocator);
        return result;
    }

    // Find first slash
    if (path[0] == '/') {
        result.* = PathPart{
            .part = path[0..1],
            .next = try parse(allocator, path[1..]),
            .alloctr = allocator,
        };
        return result;
    }

    // Find next slash
    const next_slash_or_eof = std.mem.indexOfScalar(u8, path, '/') orelse path.len;

    // Check file name length
    if (next_slash_or_eof > File.max_name_len) {
        return error.FileNameToLong;
    }

    // Create part
    result.* = PathPart{
        .part = path[0..next_slash_or_eof],
        .next = if (next_slash_or_eof < path.len)
            try parse(allocator, path[next_slash_or_eof..])
        else
            try allocator.create(PathPart),
        .alloctr = allocator,
    };

    // If there is no next slash, create empty part
    if (next_slash_or_eof == path.len) {
        result.next.?.* = PathPart.init(allocator);
    }

    return result;
}

test "empty path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parse(allocator, "");
    try testing.expect(result.part == null);
    try testing.expect(result.next == null);
}

test "single slash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parse(allocator, "/");
    try testing.expectEqualStrings("/", result.part.?);
    try testing.expect(result.next.?.part == null);
    try testing.expect(result.next.?.next == null);
}

test "absolute path with single directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parse(allocator, "/usr");
    try testing.expectEqualStrings("/", result.part.?);
    try testing.expectEqualStrings("usr", result.next.?.part.?);
    try testing.expect(result.next.?.next.?.part == null);
}

test "absolute path with multiple directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parse(allocator, "/usr/local/bin");
    try testing.expectEqualStrings("/", result.part.?);
    try testing.expectEqualStrings("usr", result.next.?.part.?);
    try testing.expectEqualStrings("/", result.next.?.next.?.part.?);
    try testing.expectEqualStrings("local", result.next.?.next.?.next.?.part.?);
    try testing.expectEqualStrings("/", result.next.?.next.?.next.?.next.?.part.?);
    try testing.expectEqualStrings("bin", result.next.?.next.?.next.?.next.?.next.?.part.?);
    try testing.expect(result.next.?.next.?.next.?.next.?.next.?.next.?.part == null);
}

test "path with double slash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parse(allocator, "/usr//bin");
    try testing.expectEqualStrings("/", result.part.?);
    try testing.expectEqualStrings("usr", result.next.?.part.?);
    try testing.expectEqualStrings("/", result.next.?.next.?.part.?);
    try testing.expectEqualStrings("/", result.next.?.next.?.next.?.part.?);
    try testing.expectEqualStrings("bin", result.next.?.next.?.next.?.next.?.part.?);
    try testing.expect(result.next.?.next.?.next.?.next.?.next.?.part == null);
}

test "relative path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parse(allocator, "local/bin");
    try testing.expectEqualStrings("local", result.part.?);
    try testing.expectEqualStrings("/", result.next.?.part.?);
    try testing.expectEqualStrings("bin", result.next.?.next.?.part.?);
    try testing.expect(result.next.?.next.?.next.?.part == null);
}

test "file name too long" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Tworzymy ścieżkę z nazwą pliku dłuższą niż File.max_name_len
    var long_name: [File.max_name_len + 1]u8 = undefined;
    @memset(&long_name, 'a');

    try testing.expectError(error.FileNameToLong, parse(allocator, &long_name));
}

test "path with dots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parse(allocator, "../test/./file");
    try testing.expectEqualStrings("..", result.part.?);
    try testing.expectEqualStrings("/", result.next.?.part.?);
    try testing.expectEqualStrings("test", result.next.?.next.?.part.?);
    try testing.expectEqualStrings("/", result.next.?.next.?.next.?.part.?);
    try testing.expectEqualStrings(".", result.next.?.next.?.next.?.next.?.part.?);
    try testing.expectEqualStrings("/", result.next.?.next.?.next.?.next.?.next.?.part.?);
    try testing.expectEqualStrings("file", result.next.?.next.?.next.?.next.?.next.?.next.?.part.?);
    try testing.expect(result.next.?.next.?.next.?.next.?.next.?.next.?.next.?.part == null);
}
