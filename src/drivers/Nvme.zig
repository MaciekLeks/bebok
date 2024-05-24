const std = @import("std");
const log = std.log.scoped(.nvme);
const pci = @import("pci.zig");
const paging = @import("../paging.zig");

const nvme_class_code = 0x01;
const nvme_subclass = 0x08;
const nvme_prog_if = 0x02;

const Self = @This();

pub fn interested(_: Self, class_code: u8, subclass: u8, prog_if: u8) bool {
    return class_code == nvme_class_code and subclass == nvme_subclass and prog_if == nvme_prog_if;
}

pub fn update(_: Self,  function: u3, slot: u5, bus: u8) void {
    const bar = pci.readBARWithArgs(.bar0, function, slot, bus);
    pci.enableBusMastering(function, slot, bus);

   const vaddr = switch (bar.address) {
        inline else  => |addr| paging.vaddrFromPaddr(addr),
    };
    const cap_reg_ptr : *volatile u64 = @ptrFromInt(vaddr);
    const vs_reg_ptr : *volatile u32 = @ptrFromInt(vaddr + 0x08);
    const intmc_reg_ptr : *volatile u32 = @ptrFromInt(vaddr + 0x04);
    const intms_reg_ptr : *volatile u32 = @ptrFromInt(vaddr + 0x0c);
    const cc_reg_ptr : *volatile u32 = @ptrFromInt(vaddr + 0x14);
    const csts_reg_ptr : *volatile u32 = @ptrFromInt(vaddr + 0x1c);
    const aqa_reg_ptr : *volatile u32 = @ptrFromInt(vaddr + 0x24);
    const asq_reg_ptr : *volatile u64 = @ptrFromInt(vaddr + 0x28);
    const acq_reg_ptr : *volatile u64 = @ptrFromInt(vaddr + 0x30);



    log.warn(\\bar:{}, addr:0x{x},
            \\cap: 0b{b:0>64}, vs: 0b{b:0>32}
            \\intms: 0b{b:0>32}, intmc: 0b{b:0>32}
            \\cc: 0b{b:0>32}, csts: 0b{b:0>32}
            \\aqa: 0b{b:0>32}, asq: 0b{b:0>64}, acq: 0b{b:0>64}
        ,
        .{
            bar,
            vaddr,
            cap_reg_ptr.*,
            vs_reg_ptr.*,
            intms_reg_ptr.*,
            intmc_reg_ptr.*,
            cc_reg_ptr.*,
            csts_reg_ptr.*,
            aqa_reg_ptr.*,
            asq_reg_ptr.*,
            acq_reg_ptr.*,
        }
    );


}

var driver = &pci.Driver{ .nvme = &Self{} };

pub fn init() void {
    log.info("Initializing NVMe driver", .{});
    pci.registerDriver(driver) catch |err| {
        log.err("Failed to register NVMe driver: {}", .{err});
        @panic("Failed to register NVMe driver");
    };
}

pub fn deinit() void {
    log.info("Deinitializing NVMe driver", .{});
    // TODO: for now we don't have a way to unregister the driver
}
