const std = @import("std");

const NvmeDevice = @import("../deps.zig").NvmeDevice;

const e = @import("../errors.zig");
const regs = @import("../registers.zig");
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
fn execAdminCommand(CDw0Type: type, dev: *NvmeDevice, cmd: com.SQEntry, sqn: u16, cqn: u16) e.NvmeError!com.CQEntry {
    const cdw0: *const CDw0Type = @ptrCast(@alignCast(&cmd));
    log.debug("Executing command: CDw0: {}", .{cdw0.*});

    dev.sq[sqn].entries[dev.sq[sqn].tail_pos] = cmd;

    dev.sq[sqn].tail_pos += 1;
    if (dev.sq[sqn].tail_pos >= dev.sq[sqn].entries.len) dev.sq[sqn].tail_pos = 0;

    const cq_entry_ptr = &dev.cq[cqn].entries[dev.cq[cqn].head_pos];

    // press the doorbell
    dev.sq[sqn].tail_dbl.* = dev.sq[sqn].tail_pos;

    log.debug("Phase mismatch: CQEntry: {}, expected phase: {}", .{ cq_entry_ptr.phase, dev.cq[cqn].expected_phase });
    while (cq_entry_ptr.phase != dev.cq[cqn].expected_phase) {
        //log phase mismatch
        //log.debug("Phase mismatch(loop): CQEntry: {}, expected phase: {}", .{ cq_entry_ptr.*, drv.cq[cqn].expected_phase });

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

    if (cdw0.cid != cq_entry_ptr.cmd_id) {
        log.err("Invalid CID in CQEntry: {} for CDw0: {}", .{ cq_entry_ptr.*, cdw0 });
        return e.NvmeError.InvalidCommandSequence;
    }

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
        log.err("Command failed (sc != 0): CDw0: {}, CQEntry: {}", .{ cdw0, cq_entry_ptr.* });
        return e.NvmeError.AdminCommandFailed;
    }

    log.debug("Command executed successfully: CDw0: {}, CQEntry = {}", .{ cdw0, cq_entry_ptr.* });
    return cq_entry_ptr.*;
}

pub fn executeAdminCommand(dev: *NvmeDevice, cmd: com.SQEntry) e.NvmeError!com.CQEntry {
    return execAdminCommand(AdminCDw0, dev, cmd, 0, 0);
}
