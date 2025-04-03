const std = @import("std");

const cpu = @import("core").cpu;
const Pcie = @import("bus").Pcie;

const NvmeController = @import("../NvmeController.zig");
const e = @import("../errors.zig");
const regs = @import("../registers.zig");
const com = @import("../commons.zig");
const log = std.log.scoped(.nvme_io);

const io = @import("io.zig"); //?

const IoNvmOpcode = enum(u8) {
    write = 0x01,
    read = 0x02,
};

pub const IoNvmCDw0 = com.GenNCDw0(IoNvmOpcode);

fn execIoCommand(CDw0Type: type, dev: *NvmeController, cmd: com.SQEntry, sqn: u16, cqn: u16) e.NvmeError!com.CQEntry {
    const cdw0: *const CDw0Type = @ptrCast(@alignCast(&cmd));
    log.debug("Executing command: CDw0: {}", .{cdw0.*});

    if (cdw0.opc == .read) {
        const read_cmd: io.IoNvmCommandSetCommand.Read = @bitCast(cmd);
        log.debug("commented out /0 Read command: {}", .{read_cmd});
    }

    dev.sq[sqn].entries[dev.sq[sqn].tail_pos] = cmd;

    log.debug("commented out /1 tail_pos:{}", .{dev.sq[sqn].tail_pos});

    dev.sq[sqn].tail_pos += 1;
    if (dev.sq[sqn].tail_pos >= dev.sq[sqn].entries.len) dev.sq[sqn].tail_pos = 0;

    log.debug("commented out /2", .{});

    //?
    while (true) {
        const cq_entry_ptr = &dev.cq[cqn].entries[dev.cq[cqn].head_pos];

        //show first 100 bytes of cq_entry_ptr
        //const dump: [*]const u8 = @as([*]const u8, @ptrCast(@volatileCast(@alignCast(cq_entry_ptr))));
        //for (0..100) |i| {
        //    log.debug("cq_entry_ptr[{}]: {}", .{ i, dump[i] });
        //}

        // press the doorbell
        dev.sq[sqn].tail_dbl.* = dev.sq[sqn].tail_pos;
        log.debug("commented out /3", .{});

        log.debug("commented out /4", .{});

        log.debug("commented out /5", .{});

        // TODO: this silly loop must be removed
        // while (!dev.mutex) {
        //     log.debug("Waiting for the controller to be ready", .{});
        //     // TODO: refactor this
        //     //const pending_bit = Pcie.readMsixPendingBitArrayBit(drv.msix_cap, drv.bar, tmp_msix_table_idx);
        //     //log.debug("MSI-X pending bit: {}", .{pending_bit});
        //     cpu.halt();
        // }
        // dev.mutex = false;

        //dev.mutex.lock();
        //const irqs = dev.irqs_count;
        //dev.mutex.unlock();
        const req_ints = @atomicLoad(u8, &dev.req_ints_count, .monotonic);

        log.debug("commented out /5.0 irqs={d}", .{req_ints});

        if (req_ints == 0) {
            cpu.halt();
            //continue; //commented out to avoid deadlock at the 3rd of April 2025
            break; //break to avoid deadlock at the 3rd of April 2025
        }

        log.debug("commented out /5.1 irqs={d}, cq_entry_ptr={}, expected_phase={}", .{ req_ints, cq_entry_ptr, dev.cq[cqn].expected_phase });

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

        //dev.mutex.lock();
        //dev.irqs_count -= 1;
        //dev.mutex.unlock();
        _ = @atomicRmw(u8, &dev.req_ints_count, .Sub, 1, .monotonic);

        //?
        if (cdw0.cid != cq_entry_ptr.cmd_id) {
            log.err("Workaround: Invalid CID in CQEntry: {} for CDw0: {}", .{ cq_entry_ptr.*, cdw0 });
            //TOOD: remove this
            //Qemu sends FLUSH every new cycle, this commands ends with sc=11, sct=0 then the right command is executed
            //successfully and there is no new entry in cq (should be 2, one for flush and one for my readRegister),
            //so we need to check if the command is executed successfully
            // pci_nvme_mmio_write addr 0x1008 data 0x0 size 4
            // pci_nvme_mmio_doorbell_sq sqid 1 new_tail 0
            // pci_nvme_io_cmd cid 8 nsid 0x1 sqid 1 opc 0x2 opname 'NVME_NVM_CMD_READ'
            // pci_nvme_read cid 8 nsid 1 nlb 1 count 512 lba 0x802
            // pci_nvme_map_prp trans_len 512 len 512 prp1 0x144000 prp2 0x0 num_prps 1
            // pci_nvme_map_addr addr 0x144000 len 512
            // pci_nvme_io_cmd cid 0 nsid 0x0 sqid 1 opc 0x0 opname 'NVME_NVM_CMD_FLUSH'
            // pci_nvme_enqueue_req_completion cid 0 cqid 1 dw0 0x0 dw1 0x0 status 0x400b
            // pci_nvme_err_req_status cid 0 nsid 0 status 0x400b opc 0x0
            // pci_nvme_irq_msix raising MSI-X IRQ vector 1
            // apic_deliver_irq dest 0 dest_mode 0 delivery_mode 0 vector 33 trigger_mode 0
            // pci_nvme_rw_cb cid 8 blk 'drv0'
            // pci_nvme_rw_complete_cb cid 8 blk 'drv0'
            // pci_nvme_enqueue_req_completion cid 8 cqid 1 dw0 0x0 dw1 0x0 status 0x0
            // pci_nvme_irq_msix raising MSI-X IRQ vector 1
            // apic_deliver_irq dest 0 dest_mode 0 delivery_mode 0 vector 33 trigger_mode 0
            // pic_register_write register 0x0b = 0x0
            // The Workaraound:
            if (cq_entry_ptr.cmd_id == 0 and cq_entry_ptr.status.sc == 11) {
                log.debug("Workaround: Command executed successfully: CDw0: {}, CQEntry = {}", .{ cdw0, cq_entry_ptr.* });
                //dev.mutex.lock();
                //dev.irqs_count = 0;
                //dev.mutex.unlock();
                @atomicStore(u8, &dev.req_ints_count, 0, .monotonic);
                return cq_entry_ptr.*;
            }
            //The code that should work but it's doesn't:
            //continue;
        }

        if (cq_entry_ptr.status.sc != 0) {
            log.err("Command CDw0: {} failed: {}", .{ cdw0, cq_entry_ptr.* });
            return e.NvmeError.AdminCommandFailed;
        } else {
            log.debug("Command executed successfully: CDw0: {}, CQEntry = {}", .{ cdw0, cq_entry_ptr.* });
            return cq_entry_ptr.*;
        }
    } //? while
}

pub fn executeIoNvmCommand(dev: *NvmeController, cmd: com.SQEntry, sqn: u16, cqn: u16) e.NvmeError!com.CQEntry {
    return execIoCommand(IoNvmCDw0, dev, cmd, sqn, cqn);
}
