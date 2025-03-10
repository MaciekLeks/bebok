const std = @import("std");
const Iterator = @import("lang").iter.Iterator;
const PageNum = @import("../../types.zig").PageNum;
const Node = @import("../../Node.zig");
const MockPage = @import("./page.zig").MockPage;

pub fn createMockNode(allocator: std.mem.Allocator, pages: []const MockPage) !Node {
    const MockPageIter = struct {
        const Self = @This();

        //Fields
        page_num: PageNum = 0,
        page_count: usize = 0,

        pub fn next(self: *Self) !?PageNum {
            if (self.page_num >= self.page_count) return null;
            defer self.page_num += 1;
            return self.page_num;
        }

        pub fn destroy(_: *const Self) void {
            std.debug.print("MockPageIter destroy\n", .{});
        }
    };

    const MockNodeImpl = struct {
        const Self = @This();

        //Fields
        alloctr: std.mem.Allocator,
        page_num: PageNum = 0,
        data: usize = 0,
        pages: []const MockPage,
        page_iter: MockPageIter = undefined,

        pub fn new(a: std.mem.Allocator, pgs: []const MockPage) !*Self {
            const self = try a.create(Self);
            self.* = .{
                .alloctr = a,
                .pages = try a.dupe(MockPage, pgs),
                .page_iter = .{
                    .page_num = 0,
                    .page_count = pgs.len,
                },
            };
            return self;
        }

        pub fn readPage(ctx: *Self, pg_num: PageNum, buf: []u8) anyerror!void {
            @memcpy(buf, std.mem.sliceAsBytes(ctx.pages[pg_num .. pg_num + 1]));
        }

        pub fn getPageIter(ctx: *Self, _: std.mem.Allocator, _: Node) Iterator(PageNum) {
            return Iterator(PageNum).init(&ctx.page_iter);
        }

        pub fn getFileSize(ctx: *Self, _: Node) ?usize {
            return ctx.pages.len;
        }

        // pub fn next(self: *Self) !?PageNum {
        //     if (self.page_num >= self.pages.len) return null;
        //     defer self.page_num += 1;
        //     return self.page_num;
        // }

        pub fn destroy(self: *const Self) void {
            std.debug.print("MockNode destroy\n", .{});
            self.alloctr.free(self.pages);
            self.alloctr.destroy(self);
        }
    };

    const mockFsNodeImpl = try MockNodeImpl.new(allocator, pages);
    return Node.init(mockFsNodeImpl, 1, &mockFsNodeImpl.data);
}
