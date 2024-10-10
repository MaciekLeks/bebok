const std = @import("std");

const NvmeController = @import("../deps.zig").NvmeController;
const cpu = @import("../deps.zig").cpu;
const Pcie = @import("../deps.zig").Pcie;

const e = @import("../errors.zig");
const regs = @import("../deps.zig").regs;
const com = @import("../commons.zig");

const log = std.log.scoped(.drivers_nvme);

const IoNvmOpcode = enum(u8) {
    write = 0x01,
    read = 0x02,
};

pub const IoNvmCDw0 = com.GenNCDw0(IoNvmOpcode);

fn execIoCommand(CDw0Type: type, dev: *NvmeController, cmd: com.SQEntry, sqn: u16, cqn: u16) e.NvmeError!com.CQEntry {
    const cdw0: *const CDw0Type = @ptrCast(@alignCast(&cmd));
    log.debug("Executing command: CDw0: {}", .{cdw0.*});

    dev.sq[sqn].entries[dev.sq[sqn].tail_pos] = cmd;

    log.debug("commented out /1", .{});

    dev.sq[sqn].tail_pos += 1;
    if (dev.sq[sqn].tail_pos >= dev.sq[sqn].entries.len) dev.sq[sqn].tail_pos = 0;

    log.debug("commented out /2", .{});

    const cq_entry_ptr = &dev.cq[cqn].entries[dev.cq[cqn].head_pos];

    // press the doorbell
    dev.sq[sqn].tail_dbl.* = dev.sq[sqn].tail_pos;
    log.debug("commented out /3", .{});

    log.debug("commented out /4", .{});

    log.debug("commented out /5", .{});

    // TODO: this silly loop must be removed
    while (!dev.mutex) {
        log.debug("Waiting for the controller to be ready", .{});
        // TODO: refactor this
        //const pending_bit = Pcie.readMsixPendingBitArrayBit(drv.msix_cap, drv.bar, tmp_msix_table_idx);
        //log.debug("MSI-X pending bit: {}", .{pending_bit});
        cpu.halt();
    }
    dev.mutex = false;

    while (cq_entry_ptr.phase != dev.cq[cqn].expected_phase) {
        const csts = regs.readRegister(regs.CSTSRegister, dev.bar, .csts);
        if (csts.cfs == 1) {
            log.err("Command failed", .{});
            return e.NvmeError.InvalidCommand;
        }
        if (csts.shst != 0) {
            if (csts.st == 1) log.err("NVE Subsystem is in shutdown state", .{}) else log.err("Controller is in shutdown state", .{});

            log.err("Controller is in shutdown state", .{});
            return e.NvmeError.InvalidCommand;
        }
        if (csts.nssro == 1) {
            log.err("Controller is not ready", .{});
            return e.NvmeError.InvalidCommand;
        }
        if (csts.pp == 1) {
            log.err("Controller is in paused state", .{});
            return e.NvmeError.InvalidCommand;
        }
    }

    log.debug("commented out /5", .{});

    // TODO: do we need to check if conntroller is ready to accept new commands?
    //--  drv.asqa.header_pos = cqa_entry_ptr.sq_header_pos; //the controller position retuned in CQEntry as sq_header_pos
    dev.cq[cqn].head_pos += 1;
    if (dev.cq[cqn].head_pos >= dev.cq[cqn].entries.len) {
        dev.cq[cqn].head_pos = 0;
        // every new cycle we need to toggle the phase
        dev.cq[cqn].expected_phase = ~dev.cq[cqn].expected_phase;
    }

    //press the doorbell
    dev.cq[cqn].head_dbl.* = dev.cq[cqn].head_pos;

    if (sqn != cq_entry_ptr.sq_id) {
        log.err("Invalid SQ ID in CQEntry: {} for CDw0: {}", .{ cq_entry_ptr.*, cdw0 });
        return e.NvmeError.InvalidCommandSequence;
    }

    if (cq_entry_ptr.status.sc != 0) {
        log.err("Command failed: {}", .{cq_entry_ptr.*});
        return e.NvmeError.AdminCommandFailed;
    }

    log.debug("Command executed successfully: CDw0: {}, CQEntry = {}", .{ cdw0, cq_entry_ptr.* });
    return cq_entry_ptr.*;
    // return CQEntry{};
}

pub fn executeIoNvmCommand(dev: *NvmeController, cmd: com.SQEntry, sqn: u16, cqn: u16) e.NvmeError!com.CQEntry {
    return execIoCommand(IoNvmCDw0, dev, cmd, sqn, cqn);
}
