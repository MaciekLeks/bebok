const std = @import("std");
const limine = @import("limine");

const log = std.log.scoped(.acpi);

pub export var rsdp_request = limine.RsdpRequest{};

pub fn init() void {
    if (rsdp_request.response) |response| {
        log.info("RSDP reponse: {}", .{response.*});
    }
}
