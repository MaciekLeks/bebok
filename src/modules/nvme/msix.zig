const Pcie = @import("deps.zig").Pcie;
const int = @import("deps.zig").int;

const NvmeController = @import("NvmeController.zig");

pub fn configureMsix(dev: *NvmeController, msix_table_idx: u11, int_vec_no: u8) !void {
    const addr = dev.base.addr.pcie;
    const unique_id = Pcie.uniqueId(addr);

    const isr_closure = try dev.base.alloctr.create(int.ISRHandler);
    isr_closure.* = .{ .unique_id = unique_id, .ctx = dev, .func = handleInterrupt };
    //TODO: who is responsible for freeing the closure?

    try int.addISR(@intCast(int_vec_no), isr_closure);
    Pcie.addMsixMessageTableEntry(dev.msix_cap, dev.bar, msix_table_idx, int_vec_no); //add 0x31 at 0x01 offset
}

// TODO move to a separate module
pub fn handleInterrupt(ctx: ?*anyopaque) !void {
    var dev: *NvmeController = @ptrCast(@alignCast(ctx));
    dev.mutex = true;
    // Never use log inside the interrupt handler
    //log.warn("apic : MSI-X : We've got it: NVMe interrupt handled.", .{});
}
