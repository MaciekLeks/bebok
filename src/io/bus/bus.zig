const std = @import("std");

const Pcie = @import("pci/pcie.zig").Pcie;
const heap = @import("../../mem/heap.zig").heap;

const log = std.log.scoped(.bus);

pub const Bus = union(enum) {
    const Self = @This();
    pcie: Pcie,

    pub fn init(self: Self, allocator: std.mem.Allocator) void {
        switch (self) {
            .pcie => Pcie.init(allocator),
        }
    }

    pub fn deinit(self: Bus) void {
        switch (self) {
            .pci => |pci| pci.deinit(),
        }
    }

    pub fn scan(self: Self) !void {
        switch (self) {
            .pci => |pci| try pci.scan(),
        }
    }
};
