pub const Pcie = @import("../deps.zig").Pcie;
pub const BlockDevice = @import("../deps.zig").BlockDevice;
pub const NvmeController = @import("../deps.zig").NvmeController;
pub const Device = @import("../deps.zig").Device;
pub const int = @import("../deps.zig").int;
pub const paging = @import("../deps.zig").paging;
pub const cpu = @import("../deps.zig").cpu;
pub const pmm = @import("../../mem/pmm.zig");
pub const heap = @import("../../mem/heap.zig").heap;

pub const Driver = @import("../Driver.zig");

pub const regs = @import("../../commons/nvme/mod.zig").regs;
