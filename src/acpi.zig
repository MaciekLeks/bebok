const std = @import("std");
const limine = @import("limine");

const log = std.log.scoped(.acpi);

pub export var rsdp_request: limine.RsdpRequest = .{};

const Rsdp = extern struct {
    signature: [8]u8 align(1),
    checksum: u8 align(1),
    oem_id: [6]u8 align(1),
    revision: u8 align(1),
    rsdt_address: u32 align(1),
};

const Xsdp = extern struct {
    rsdp: Rsdp align(1),
    length: u32 align(1),
    xsdt_address: u64 align(1),
    extended_checksum: u8,
    reserved: [3]u8 align(1),
};

const SystemDescriptorPointer = union(enum) { root: *align(1) Rsdp, extended: *align(1) Xsdp };

var sdp: SystemDescriptorPointer = undefined;

pub fn init() !void {
    if (rsdp_request.response) |response| {
        const rsdp: *Rsdp = @ptrCast(@alignCast(response.address));
        log.info("Revision: {}", .{rsdp.*});

        switch (rsdp.revision) {
            0 => {
                //sdp = .{ .root = rsdp }; //TODO not working
                sdp = SystemDescriptorPointer{ .root = rsdp };
                log.info("RSDP: {}", .{sdp.root.*});
                return error.ACPC1NotSupported;
            },
            else => {
                //sdp.extended = .{ .extended = @ptrCast(@alignCast(response.address)) }; //not working
                sdp = SystemDescriptorPointer{ .extended = @ptrCast(@alignCast(response.address)) };
                log.info("XSDP: {}", .{sdp.extended.*});
            },
        }
    }
}
