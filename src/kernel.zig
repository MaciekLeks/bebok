const std = @import("std");
const builtin = @import("builtin");
const limine = @import("limine");
const config = @import("config");
//const start = @import("start.zig");
const term = @import("terminal");

const DriverRegistry = @import("drivers").Registry;
const devices = @import("devices");
const Device = devices.Device;
const BlockDevice = devices.BlockDevice;
const NvmeDriver = @import("nvme").NvmeDriver;
const fs = @import("fs");
//const pathparser = fs.pathparser;
const Vfs = fs.Vfs;
const FilesystemDriver = fs.FilesystemDriver;
const Filesystem = fs.Filesystem;
const FilesystemDriversRegistry = fs.Registry;
const ext2 = @import("ext2");
const Ext2Driver = ext2.Ext2Driver;
//
const core = @import("core");
// const acpi = core.acpi;
const cpu = core.cpu;
const int = core.int;
const paging = core.paging;
const smp = core.smp;
const segmentation = core.segmentation;
const mem = @import("mem");
const pmm = mem.pmm;
const heap = mem.heap;

const sched = @import("sched");
//

pub const bus = @import("bus");
//?const apic_test = @import("core/arch/x86_64/apic.zig");

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

pub const std_options: std.Options = .{
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

comptime {
    if (!builtin.is_test) {
        @export(&_start, .{ .name = "_start", .linkage = .strong });
    }
}

fn _start() callconv(.C) noreturn {
    //export fn _start() callconv(.C) noreturn {
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

    cpu.sti();

    // Scan all block devices already found for partition schemes and partitions
    BlockDevice.scanBlockDevices(pcie_bus, arena_allocator.allocator()) catch |err| {
        log.err("Block device scan error: {}", .{err});
        @panic("Block device scan error");
    };

    const fs_reg = FilesystemDriversRegistry.new(arena_allocator.allocator()) catch |err| {
        log.err("Filesystem drivers registry creation error: {}", .{err});
        @panic("Filesystem drivers registry creation error");
    };
    defer fs_reg.destroy();

    const ext2_driver = arena_allocator.allocator().create(Ext2Driver) catch |err| {
        log.err("Ext2 filesystem driver creation error: {}", .{err});
        @panic("Ext2 filesystem driver registration error");
        //
    };
    fs_reg.registerFileSystemDriver(ext2_driver.driver()) catch |err| {
        log.err("Ext2 filesystem driver registration error: {}", .{err});
        @panic("Ext2 filesystem driver registration error");
    };

    //Init VFS
    const vfs = Vfs.init(arena_allocator.allocator()) catch |err| {
        log.err("VFS initialization error: {}", .{err});
        @panic("VFS initialization error");
    };

    log.info("Scanning block devices for filesystems", .{});
    Filesystem.scanBlockDevices(arena_allocator.allocator(), pcie_bus, fs_reg, vfs) catch |err| {
        log.err("Filesystem scan error: {}", .{err});
        @panic("Filesystem scan error");
    };
    log.info("Scanning block devices for filesystems finished", .{});

    //const tst_ns = pcie_bus.devices.items[0].spec.block.spec.nvme_ctrl.namespaces.get(1);
    for (pcie_bus.devices.items) |*dev_node| {
        //log.warn("Device: {}", .{dev_node}); //TODO:  prontformat method needed to avoid tripple fault

        if (dev_node.device.kind == Device.Kind.block) {
            const block_dev = BlockDevice.fromDevice(dev_node.device);

            if (block_dev.kind == .logical) {
                const streamer = block_dev.streamer();

                var stream = BlockDevice.Stream(u8).init(streamer);

                // Go to superblock position, always 1024 in the ext2 partition
                stream.seek(0x400, .start);

                //log.debug("admin.identify.IdentifyNamespaceInfo: ptr:{*}, info:{}", .{ ns, ns.info });

                log.info("Reading from NVMe starts.", .{});
                const data = stream.read(heap.page_allocator, 128) catch |err| blk: {
                    log.err("Nvme read error: {}", .{err});
                    break :blk null;
                };
                for (data.?) |d| {
                    log.warn("Nvme data: {x}", .{d});
                }
                if (data) |block| heap.page_allocator.free(block);
            } //partition only
        } //block device condition
    } //loop over bus devices

    //VFS example start
    var task = sched.Task{};
    const fd = vfs.open(&task, "/file01.txt", .{ .read = true }, .{}) catch |err| {
        log.err("VFS open error: {s}", .{@errorName(err)});
        @panic("VFS open error");
    };
    log.info("VFS open and fd is {d}", .{fd});

    var fbuf = [_]u8{0} ** 50;
    const read_bytes = vfs.read(&task, fd, &fbuf) catch |err| {
        log.err("VFS read error: {s}", .{@errorName(err)});
        @panic("VFS read error");
    };
    log.info("VFS read {d} bytes", .{read_bytes});
    //log bytes to the console till read_bytes
    for (0..read_bytes) |i| {
        log.info("{x}", .{fbuf[i]});
    }
    //VFS example end

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
//

// comptime {
//     @compileLog("Loading kernel.zig as root");
// }
