const std = @import("std");
const Pcie = @import("mod.zig").Pcie;

const log = std.log.scoped(.drivers_nvme);

const regs = @import("registers.zig");

pub fn disableController(bar: Pcie.Bar) void {
    toggleController(bar, false);
}

pub fn enableController(bar: Pcie.Bar) void {
    toggleController(bar, true);
}

fn toggleController(bar: Pcie.Bar, enable: bool) void {
    var cc = regs.readRegister(regs.CCRegister, bar, .cc);
    log.info("CC register before toggle: {}", .{cc});
    cc.en = if (enable) 1 else 0;
    regs.writeRegister(regs.CCRegister, bar, .cc, cc);

    cc = regs.readRegister(regs.CCRegister, bar, .cc);
    log.info("CC register after toggle: {}", .{cc});

    while (regs.readRegister(regs.CSTSRegister, bar, .csts).rdy != @intFromBool(enable)) {}

    log.info("NVMe controller is {s}", .{if (enable) "enabled" else "disabled"});
}
