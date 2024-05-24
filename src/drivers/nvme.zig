const std = @import("std");
const log = std.log.scoped(.nvme);
const pci = @import("pci.zig");

const nvme_class_code = 0x01;
const nvme_subclass = 0x08;
const nvme_prog_if = 0x02;

pub const Controller =  struct {
    const Self = @This();
    pub fn interested(_: Self, class_code: u8, subclass: u8, prog_if: u8) bool {
        return class_code == nvme_class_code and subclass == nvme_subclass and prog_if == nvme_prog_if;
    }

    pub fn update(_ : Self) void {
        log.info("Yey, it's me", .{});
    }
};

var driver = &pci.Driver{ .nvme = &Controller{} };

pub fn init() void {
    log.info("Initializing NVMe driver", .{});
    pci.registerDriver(driver) catch |err| {
        log.err("Failed to register NVMe driver: {}", .{err});
        @panic("Failed to register NVMe driver");
    };
}

pub fn deinit() void {
    log.info("Deinitializing NVMe driver", .{});
    // TODO: for now we don't have a way to unregister the driver
}
