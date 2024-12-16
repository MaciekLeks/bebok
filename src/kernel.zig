const std = @import("std");
const builtin = @import("builtin");
const limine = @import("limine");
const config = @import("config");
//const start = @import("start.zig");
const segmentation = @import("segmentation.zig");
const term = @import("terminal");

pub const Bus = @import("bus/bus.zig").Bus;
pub const BusDeviceAddress = @import("bus/bus.zig").BusDeviceAddress;
pub const Driver = @import("drivers/Driver.zig");
pub const Device = @import("devices/Device.zig");
pub const PhysDevice = @import("devices/PhysDevice.zig");
pub const BlockDevice = @import("devices/mod.zig").BlockDevice;
pub const PartitionScheme = @import("devices/mod.zig").PartitionScheme;
pub const Partition = @import("devices/mod.zig").Partition;
pub const Guid = @import("commons/guid.zig").Guid;
pub const FileSystem = @import("fs/FileSystem.zig");
const DriverRegistry = @import("drivers/Registry.zig");
const NvmeDriver = @import("nvme").NvmeDriver;
const NvmeNamespace = @import("nvme").NvmeNamespace;
const FileSystemRegistry = @import("fs/Registry.zig");
const Ext2 = @import("ext2").Ext2;
const smp = @import("smp.zig");
const acpi = @import("acpi.zig");

pub const bus = @import("bus/mod.zig");
pub const cpu = @import("cpu.zig");
pub const int = @import("int.zig");
pub const paging = @import("paging.zig");
pub const pmm = @import("mem/pmm.zig");
pub const heap = @import("mem/heap.zig").heap;

const apic_test = @import("arch/x86_64/apic.zig");

const log = std.log.scoped(.kernel);

pub export var base_revision: limine.BaseRevision = .{ .revision = 1 };

const logo =
    \\   /(,-.   )\.---.     /(,-.     .-./(      .'( 
    \\,' _   ) (   ,-._(  ,' _   )  ,'     )  ,')\  )
    \\(  '-' (   \  '-,   (  '-' (  (  .-, (  (  '/ / 
    \\ )  _   )   ) ,-`    )  _   )  ) '._\ )  )   (  
    \\(  '-' /   (  ``-.  (  '-' /  (  ,   (  (  .\ \ 
    \\ )/._.'     )..-.(   )/._.'    )/ ._.'   )/  )/ 
;

pub const std_options = .{
    .logFn = logFn,
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .bbtree, .level = .info },
    },
};

//pub fn logFn(comptime message_level: std.log.Level, comptime scope: @Type(.EnumLiteral), comptime format: []const u8, args: anytype) void {
pub fn logFn(comptime message_level: std.log.Level, comptime scope: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
    var log_allocator_buf: [4096 * 8]u8 = undefined;
    var log_fba = std.heap.FixedBufferAllocator.init(&log_allocator_buf);
    const log_allocator = log_fba.allocator();

    const prefix = switch (message_level) {
        .info => "\x1b[34m",
        .warn => "\x1b[33m",
        .err => "\x1b[31m",
        .debug => "\x1b[90m",
    } ++ "[" ++ @tagName(message_level) ++ "]\x1b[0m (" ++ @tagName(scope) ++ ")";

    const msg = std.fmt.allocPrint(log_allocator, prefix ++ " " ++ format, args) catch "\x1b[31m\x1b[1m!!!LOG_FN_OOM!!!\x1b[0m";

    for (msg) |char| {
        cpu.putb(char);
        if (char == '\n') {
            for (0..prefix.len - 10) |_| cpu.putb(' ');
            cpu.putb('|');
            cpu.putb(' ');
        }
    }

    cpu.putb('\n');
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    log.err("{s}", .{msg});

    cpu.halt();
}

export fn _start() callconv(.C) noreturn {
    // Ensure the bootloader actually understands our base revision (see spec).
    if (!base_revision.is_supported()) {
        cpu.halt();
    }

    //TODO: uncomment out this block if LAPIC problem is solved
    smp.init();

    cpu.cli();
    segmentation.init();

    paging.init() catch |err| {
        log.err("Paging initialization error: {}", .{err});
        @panic("Paging initialization error");
    };

    // acpi.init() catch |err| {
    //     log.err("ACPI initialization error: {}", .{err});
    //     @panic("ACPI initialization error");
    // };

    pmm.init() catch |err| {
        log.err("PMM initialization error: {}", .{err});
        @panic("PMM initialization error");
    };
    defer pmm.deinit(); //TODO not here

    const allocator = heap.page_allocator;
    const memory = allocator.alloc(u8, 0x3000) catch |err| {
        log.err("OOM: {}", .{err});
        @panic("OOM");
    };
    log.warn("Allocated memory at {*}", .{memory});
    allocator.free(memory);

    //{  init handler list
    var arena_allocator = std.heap.ArenaAllocator.init(heap.page_allocator);
    int.init(int.processISRList, int.defaultPool()) catch |err| {
        log.err("Interrupt initialization error: {}", .{err});
        @panic("Interrupt initialization error");
    };
    int.initISRMap(arena_allocator.allocator());
    defer int.deinitISRMap();

    int.addISR(try int.acquireAnyInterrupt(), &.{ .unique_id = 0x01, .ctx = null, .func = &testISR0 }) catch |err| {
        log.err("Failed to add Timer interrupt handler: {}", .{err});
    };
    //int.addISR(0x31, .{ .unique_id = 0x02, .func = &testISR1 }) catch |err| {
    //    log.err("Failed to add NVMe interrupt handler: {}", .{err});
    //};

    //} init handler list

    //pci test start
    var driver_reg = DriverRegistry.init(arena_allocator.allocator()) catch |err| {
        log.err("Driver registry creation error: {}", .{err});
        @panic("Driver registry creation error");
    };
    defer driver_reg.deinit();
    const nvme_driver = NvmeDriver.init(arena_allocator.allocator()) catch |err| {
        log.err("Nvme driver creation error: {}", .{err});
        @panic("Nvme driver creation error");
    };

    driver_reg.registerDriver(nvme_driver.driver()) catch |err| {
        log.err("Nvme driver registration error: {}", .{err});
        @panic("Nvme driver registration error");
    };

    const pcie_bus = bus.Bus.init(arena_allocator.allocator(), .pcie, driver_reg) catch |err| {
        log.err("PCIe bus creation error: {}", .{err});
        @panic("PCIe bus creation error");
    };
    pcie_bus.scan() catch |err| {
        log.err("PCI scan error: {}", .{err});
        @panic("PCI scan error");
    };
    defer pcie_bus.deinit(); //TODO: na pewno?
    //pci test end

    //log.debug("waiting for the first interrupt", .{});
    //apic_test.setTimerTest();
    cpu.sti();
    //cpu.halt();
    //log.debug("waiting for the first interrupt/2", .{});

    // const tst_ns = pcie_bus.devices.items[0].spec.block.spec.nvme_ctrl.namespaces.get(1);
    // if (tst_ns) |ns| {
    //     const streamer = ns.streamer();
    //     var stream = BlockDevice.Stream(u8).init(streamer);
    //     log.info("Writing to NVMe starts.", .{});
    //     defer log.info("Writing to NVMe ends.", .{});
    //     //
    //     const mlk_data: []const u8 = &.{ 'M', 'a', 'c', 'i', 'e', 'k', ' ', 'L', 'e', 'k', 's', ' ' };
    //     stream.write(mlk_data) catch |err| blk: {
    //         log.err("Nvme write error: {}", .{err});
    //         break :blk;
    //     };
    //
    //     // read from the beginning
    //     stream.seek(1); //we ommit the first byte (0x4d)
    //
    //     log.info("Reading from NVMe starts.", .{});
    //     const data = stream.read(heap.page_allocator, mlk_data.len) catch |err| blk: {
    //         log.err("Nvme read error: {}", .{err});
    //         break :blk null;
    //     };
    //     for (data.?) |d| {
    //         log.warn("Nvme data: {x}", .{d});
    //     }
    //     if (data) |block| heap.page_allocator.free(block);
    // }

    const fs_reg = FileSystemRegistry.init(arena_allocator.allocator()) catch |err| {
        log.err("Filesystem registry creation error: {}", .{err});
        @panic("Filesystem registry creation error");
    };
    defer fs_reg.deinit();

    var ext2: Ext2 = .{};
    fs_reg.registerFileSystem(ext2.filesystem()) catch |err| {
        log.err("Ext2 filesystem registration error: {}", .{err});
        @panic("Ext2 filesystem registration error");
    };

    //const tst_ns = pcie_bus.devices.items[0].spec.block.spec.nvme_ctrl.namespaces.get(1);
    for (pcie_bus.devices.items) |dev_node| {
        log.warn("Device: {}", .{dev_node});

        if (dev_node.device.kind == Device.Kind.block) {
            const block_dev = BlockDevice.fromDevice(dev_node.device);

            //detect partition scheme if any
            block_dev.detectPartitionScheme(arena_allocator.allocator()) catch |err| {
                log.err("Partition scheme detection error: {}", .{err});
            };

            //show partition scheme if any
            if (block_dev.state.partition_scheme) |scheme| {
                switch (scheme.spec) {
                    .gpt => |gpt| {
                        log.warn("GPT detected", .{});
                        log.warn("GPT header: {}", .{gpt.header});
                        for (gpt.entries) |entry| {
                            if (entry.isEmpty()) {
                                continue;
                            }
                            log.warn("GPT entry: {}", .{entry});
                        }
                    },
                }

                // Iterate over partitions no matter the scheme
                var it = scheme.iterator();
                while (it.next()) |partition_opt| {
                    if (partition_opt) |partition| {
                        log.debug("Partition: start_lba={}, end_lba={}, type={}, name={s}", .{ partition.start_lba, partition.end_lba, partition.partition_type, partition.name });
                    } else {
                        log.debug("No more partition", .{});
                        break;
                    }
                } else |err| {
                    log.err("Partition iteration error: {}", .{err});
                }
            }

            const streamer = block_dev.streamer();
            var stream = BlockDevice.Stream(u8).init(streamer, heap.page_allocator);

            stream.seek(0x400);

            //log.debug("admin.identify.IdentifyNamespaceInfo: ptr:{*}, info:{}", .{ ns, ns.info });

            log.info("Reading from NVMe starts.", .{});
            const data = stream.read(heap.page_allocator, 32) catch |err| blk: {
                log.err("Nvme read error: {}", .{err});
                break :blk null;
            };
            for (data.?) |d| {
                log.warn("Nvme data: {x}", .{d});
            }
            if (data) |block| heap.page_allocator.free(block);
        } //block device condition
    } //loop over bus devices

    var pty = term.GenericTerminal(term.FontPsf1Lat2Vga16).init(255, 0, 0, 255) catch @panic("cannot initialize terminal");
    pty.printf("{s}\n\nversion: {any}", .{ logo, config.kernel_version });

    {
        log.debug("TEST:Start", .{});
        const mem_test = heap.page_allocator.alloc(u8, 0x2000) catch |err| {
            log.err("OOM: {}", .{err});
            @panic("OOM");
        };
        log.debug("TEST:Allocated memory at {*}", .{mem_test});
        heap.page_allocator.free(mem_test[2..]); //it's ok, but if we narrow down the slice to the next level (e.g. page leve) than we can
        log.debug("TEST:End", .{});
    }

    //start.done(); //only now we can hlt - do not use defer after start.init();
    cpu.halt();
}

//TODO tbd
fn testISR0(_: ?*anyopaque) !void {
    log.warn("apic: 0----->>>>!!!!", .{});
}
// fn testISR1() !void {
//     log.warn("apic: 1----->>>>!!!!", .{});
// }
//
