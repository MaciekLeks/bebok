const Pcie = @import("bus").Pcie;
const int = @import("core").int;

const NvmeController = @import("NvmeController.zig");

pub fn configureMsix(ctrl: *NvmeController, msix_table_idx: u11, int_vec_no: u8) !void {
    const unique_id = Pcie.uniqueId(ctrl.phys_device.address.pcie);

    const isr_closure = try ctrl.alloctr.create(int.ISRHandler);
    isr_closure.* = .{ .unique_id = unique_id, .ctx = ctrl, .func = handleInterrupt };
    //TODO: who is responsible for freeing the closure?

    try int.addISR(@intCast(int_vec_no), isr_closure);
    Pcie.addMsixMessageTableEntry(ctrl.msix_cap, ctrl.bar, msix_table_idx, int_vec_no); //add 0x31 at 0x01 offset
}

// TODO move to a separate module
pub fn handleInterrupt(ctx: ?*anyopaque) !void {
    var ctrl: *NvmeController = @ptrCast(@alignCast(ctx));
    //ctrl.mutex = true;
    //ctrl.mutex.lock();
    //ctrl.irqs_count += 1;
    //ctrl.mutex.unlock();
    _ = @atomicRmw(u8, &ctrl.req_ints_count, .Add, 1, .monotonic);
    // Never use log inside the interrupt handler
    //log.warn("apic : MSI-X : We've got it: NVMe interrupt handled.", .{});
}
