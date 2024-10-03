const std = @import("std");
const NvmeDevice = @import("mod.zig").NvmeDevice;
const q = @import("queue.zig");
const e = @import("errors.zig");
const regs = @import("registers.zig");
const cpu = @import("mod.zig").cpu;
const Pcie = @import("mod.zig").Pcie;

const log = std.log.scoped(.drivers_nvme);

// TODO: is that the right place for this struct?
pub const DataPointer = packed union {
    prp: packed struct(u128) {
        prp1: u64,
        prp2: u64 = 0,
    },
    sgl: packed struct(u128) {
        sgl1: u128,
    },
};

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

const IoNvmOpcode = enum(u8) {
    write = 0x01,
    read = 0x02,
};

fn GenNCDw0(OpcodeType: type) type {
    return packed struct(u32) {
        opc: OpcodeType,
        fuse: u2 = 0, //0 for nromal operation
        rsvd: u4 = 0,
        psdt: u2 = 0, //0 for PRP tranfer
        cid: u16,
    };
}

pub const AdminCDw0 = GenNCDw0(AdminOpcode);
pub const IoNvmCDw0 = GenNCDw0(IoNvmOpcode);

/// Execute an admin command
/// @param CDw0Type: Command Dword 0 type
/// @param dev: NvmeDevice
/// @param cmd: SQEntry
/// @param sq_no: Submission Queue number
/// @param cq_no: Completion Queue number
fn execAdminCommand(CDw0Type: type, dev: *NvmeDevice, cmd: q.SQEntry, sqn: u16, cqn: u16) e.NvmeError!q.CQEntry {
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

pub fn executeAdminCommand(dev: *NvmeDevice, cmd: q.SQEntry) e.NvmeError!q.CQEntry {
    return execAdminCommand(AdminCDw0, dev, cmd, 0, 0);
}

fn execIoCommand(CDw0Type: type, dev: *NvmeDevice, cmd: q.SQEntry, sqn: u16, cqn: u16) e.NvmeError!q.CQEntry {
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

pub fn executeIoNvmCommand(dev: *NvmeDevice, cmd: q.SQEntry, sqn: u16, cqn: u16) e.NvmeError!q.CQEntry {
    return execIoCommand(IoNvmCDw0, dev, cmd, sqn, cqn);
}
