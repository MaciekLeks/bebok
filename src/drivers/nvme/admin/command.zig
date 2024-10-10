const std = @import("std");

const NvmeController = @import("../deps.zig").NvmeController;

const e = @import("../errors.zig");
const regs = @import("../deps.zig").regs;
const com = @import("../commons.zig");

const log = std.log.scoped(.drivers_nvme);

const AdminOpcode = enum(u8) {
    identify = 0x06,
    abort = 0x0c,
    set_features = 0x09,
    get_features = 0x0a,
    create_io_sq = 0x01,
    delete_io_sq = 0x00,
    create_io_cq = 0x05,
    delete_io_cq = 0x04,
};

pub const AdminCDw0 = com.GenNCDw0(AdminOpcode);

/// Execute an admin command
/// @param CDw0Type: Command Dword 0 type
/// @param dev: NvmeDevice
/// @param cmd: SQEntry
/// @param sq_no: Submission Queue number
/// @param cq_no: Completion Queue number
fn execAdminCommand(CDw0Type: type, ctrl: *NvmeController, cmd: com.SQEntry, sqn: u16, cqn: u16) e.NvmeError!com.CQEntry {
    const cdw0: *const CDw0Type = @ptrCast(@alignCast(&cmd));
    log.debug("Executing command: CDw0: {}", .{cdw0.*});

    ctrl.sq[sqn].entries[ctrl.sq[sqn].tail_pos] = cmd;

    ctrl.sq[sqn].tail_pos += 1;
    if (ctrl.sq[sqn].tail_pos >= ctrl.sq[sqn].entries.len) ctrl.sq[sqn].tail_pos = 0;

    const cq_entry_ptr = &ctrl.cq[cqn].entries[ctrl.cq[cqn].head_pos];

    // press the doorbell
    ctrl.sq[sqn].tail_dbl.* = ctrl.sq[sqn].tail_pos;

    log.debug("Phase mismatch: CQEntry: {}, expected phase: {}", .{ cq_entry_ptr.phase, ctrl.cq[cqn].expected_phase });
    while (cq_entry_ptr.phase != ctrl.cq[cqn].expected_phase) {
        //log phase mismatch
        //log.debug("Phase mismatch(loop): CQEntry: {}, expected phase: {}", .{ cq_entry_ptr.*, drv.cq[cqn].expected_phase });

        const csts = regs.readRegister(regs.CSTSRegister, ctrl.bar, .csts);
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

    if (cdw0.cid != cq_entry_ptr.cmd_id) {
        log.err("Invalid CID in CQEntry: {} for CDw0: {}", .{ cq_entry_ptr.*, cdw0 });
        return e.NvmeError.InvalidCommandSequence;
    }

    // TODO: do we need to check if conntroller is ready to accept new commands?
    //--  drv.asqa.header_pos = cqa_entry_ptr.sq_header_pos; //the controller position retuned in CQEntry as sq_header_pos

    ctrl.cq[cqn].head_pos += 1;
    if (ctrl.cq[cqn].head_pos >= ctrl.cq[cqn].entries.len) {
        ctrl.cq[cqn].head_pos = 0;
        // every new cycle we need to toggle the phase
        ctrl.cq[cqn].expected_phase = ~ctrl.cq[cqn].expected_phase;
    }

    //press the doorbell
    ctrl.cq[cqn].head_dbl.* = ctrl.cq[cqn].head_pos;

    if (sqn != cq_entry_ptr.sq_id) {
        log.err("Invalid SQ ID in CQEntry: {} for CDw0: {}", .{ cq_entry_ptr.*, cdw0 });
        return e.NvmeError.InvalidCommandSequence;
    }

    if (cq_entry_ptr.status.sc != 0) {
        log.err("Command failed (sc != 0): CDw0: {}, CQEntry: {}", .{ cdw0, cq_entry_ptr.* });
        return e.NvmeError.AdminCommandFailed;
    }

    log.debug("Command executed successfully: CDw0: {}, CQEntry = {}", .{ cdw0, cq_entry_ptr.* });
    return cq_entry_ptr.*;
}

pub fn executeAdminCommand(ctrl: *NvmeController, cmd: com.SQEntry) e.NvmeError!com.CQEntry {
    return execAdminCommand(AdminCDw0, ctrl, cmd, 0, 0);
}
