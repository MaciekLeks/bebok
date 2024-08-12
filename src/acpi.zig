const std = @import("std");
const limine = @import("limine");

const log = std.log.scoped(.acpi);

pub export var rsdp_request: limine.RsdpRequest = .{};

const Rsdp = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_address: u32,
};

const Xsdp = extern struct {
    rsdp: Rsdp,
    length: u32,
    xsdt_address: u64,
    extended_checksum: u8,
    reserved: [3]u8,
};

const SystemDescriptorPointer = union(enum) { root: *Rsdp, extended: *Xsdp };

var sdp: SystemDescriptorPointer = undefined;

pub fn init() void {
    if (rsdp_request.response) |response| {
        const rsdp: *Rsdp = @ptrCast(@alignCast(response.address));
        log.info("Revision: {}", .{rsdp.*});

        switch (rsdp.revision) {
            0 => {
                sdp.root = rsdp;
                log.info("RSDP: {}", .{sdp.root.*});
            },
            else => {
                sdp.extended = @ptrCast(@alignCast(response.address));
                log.info("XSDP: {}", .{sdp.extended.*});
            },
        }

        log.info("rsdt_address: 0x{x}", .{sdp.root.rsdt_address});
    }
}
