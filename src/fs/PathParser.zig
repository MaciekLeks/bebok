const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const File = @import("File.zig");

const log = std.log.scoped(.file_system_path_parser);

const PathParser = @This();

/// Possible errors that can occur during path operations
pub const PathError = error{
    /// File name exceeds the maximum allowed length
    FileNameToLong,
    /// Path component not found in the filesystem
    NotFound,
    /// Path string is malformed or contains invalid characters
    InvalidPath,
    /// Not a directory
    NotDirectory,
} || Allocator.Error;

//Fields
segments: std.ArrayList([]const u8),
is_absolute: bool,

pub fn init(allocator: Allocator) PathParser {
    return .{
        .segments = std.ArrayList([]const u8).init(allocator),
        .is_absolute = false,
    };
}

pub fn deinit(self: *PathParser) void {
    self.segments.deinit();
}

pub fn parse(self: *PathParser, path: []const u8) PathError!void {
    self.segments.clearRetainingCapacity();
    self.is_absolute = path.len > 0 and path[0] == '/';

    if (self.is_absolute) {
        try self.segments.append("/");
    }

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        if (segment.len > File.max_name_len) return error.FileNameToLong;
        try self.segments.append(segment);
    }
}

pub fn iterator(self: *const PathParser) PathIterator {
    return PathIterator{ .parser = self, .index = 0 };
}

pub fn isRoot(self: *const PathParser) bool {
    return self.is_absolute and self.segments.items.len == 1;
}

pub fn isAbsolute(self: *const PathParser) bool {
    return self.is_absolute;
}

pub const PathIterator = struct {
    parser: *const PathParser,
    index: usize,

    pub fn next(self: *PathIterator) ?[]const u8 {
        if (self.index >= self.parser.segments.items.len) return null;
        const segment = self.parser.segments.items[self.index];
        self.index += 1;
        return segment;
    }
};

test "path parser - absolute path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parser = PathParser.init(allocator);
    defer parser.deinit();

    try parser.parse("/usr/local/bin");
    try std.testing.expect(parser.isAbsolute());
    try std.testing.expectEqual(@as(usize, 4), parser.segments.items.len);
    try std.testing.expectEqualStrings("/", parser.segments.items[0]);
    try std.testing.expectEqualStrings("usr", parser.segments.items[1]);
    try std.testing.expectEqualStrings("local", parser.segments.items[2]);
    try std.testing.expectEqualStrings("bin", parser.segments.items[3]);
}

test "path parser - relative path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parser = PathParser.init(allocator);
    defer parser.deinit();

    try parser.parse("local/bin");
    try std.testing.expect(!parser.isAbsolute());
    try std.testing.expectEqual(@as(usize, 2), parser.segments.items.len);
    try std.testing.expectEqualStrings("local", parser.segments.items[0]);
    try std.testing.expectEqualStrings("bin", parser.segments.items[1]);
}

test "path parser - root path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parser = PathParser.init(allocator);
    defer parser.deinit();

    try parser.parse("/");
    try std.testing.expect(parser.isRoot());
    try std.testing.expectEqual(@as(usize, 1), parser.segments.items.len);
    try std.testing.expectEqualStrings("/", parser.segments.items[0]);
}

test "path parser - iterator test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parser = PathParser.init(allocator);
    defer parser.deinit();

    try parser.parse("/usr/local/bin");
    var it = parser.iterator();
    try std.testing.expectEqualStrings("/", it.next().?);
    try std.testing.expectEqualStrings("usr", it.next().?);
    try std.testing.expectEqualStrings("local", it.next().?);
    try std.testing.expectEqualStrings("bin", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "path parser - empty path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parser = PathParser.init(allocator);
    defer parser.deinit();

    try parser.parse("");
    try std.testing.expect(!parser.isAbsolute());
    try std.testing.expectEqual(@as(usize, 0), parser.segments.items.len);
}

test "path parser - single segment absolute path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parser = PathParser.init(allocator);
    defer parser.deinit();

    try parser.parse("/bin");
    try std.testing.expect(parser.isAbsolute());
    try std.testing.expectEqual(@as(usize, 2), parser.segments.items.len);
    try std.testing.expectEqualStrings("/", parser.segments.items[0]);
    try std.testing.expectEqualStrings("bin", parser.segments.items[1]);
}
