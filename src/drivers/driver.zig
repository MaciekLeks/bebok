const Nvme = @import("nvme/nvme.zig");
const Device = @import("../devices/devices.zig").Device;

pub const Driver = union(enum) {
    const DriverSelf = @This();
    nvme: *const Nvme,

    pub fn probe(self: DriverSelf, class_code: u8, subclass: u8, prog_if: u8) bool {
        return switch (self) {
            inline else => |it| it.probe(class_code, subclass, prog_if),
        };
    }

    pub fn setup(self: DriverSelf, Device: *Device) !void {
        return switch (self) {
            inline else => |it| it.update(function_no, slot_no, bus_no),
        };
    }
};
