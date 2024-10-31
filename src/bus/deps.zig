pub const Device = @import("../devices/Device.zig"); //re-export for the all in the directory
pub const Driver = @import("../drivers/Driver.zig"); //re-export for the all in the directory
pub const Registry = @import("../drivers/Registry.zig"); //re-export for the all in the directory

pub const cpu = @import("../cpu.zig");
pub const heap = @import("../mem/heap.zig");
pub const paging = @import("../paging.zig");
