const std = @import("std");
const Build = std.Build;
const Target = std.Target;
const Feature = std.Target.Cpu.Feature;

const bebok_iso_filename = "bebok.iso";
const bebok_disk_img_filename = "disk.img";
const kernel_version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

fn resolveTarget(b: *Build, arch: Target.Cpu.Arch) !Build.ResolvedTarget {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = switch (arch) {
            .x86_64 => blk: {
                var features = Feature.Set.empty;
                features.addFeature(@intFromEnum(Target.x86.Feature.soft_float));
                break :blk features;
            },
            else => return error.UnsupportedArch,
        },
        .cpu_features_sub = switch (arch) {
            .x86_64 => blk: {
                var features = Feature.Set.empty;
                features.addFeature(@intFromEnum(Target.x86.Feature.mmx));
                features.addFeature(@intFromEnum(Target.x86.Feature.sse));
                features.addFeature(@intFromEnum(Target.x86.Feature.sse2));
                features.addFeature(@intFromEnum(Target.x86.Feature.sse3));
                features.addFeature(@intFromEnum(Target.x86.Feature.sse4_1));
                features.addFeature(@intFromEnum(Target.x86.Feature.sse4_2));
                features.addFeature(@intFromEnum(Target.x86.Feature.ssse3));
                features.addFeature(@intFromEnum(Target.x86.Feature.avx));
                features.addFeature(@intFromEnum(Target.x86.Feature.avx2));
                features.addFeature(@intFromEnum(Target.x86.Feature.x87)); //no FPU for kvm guest
                features.addFeature(@intFromEnum(Target.x86.Feature.fma));
                features.addFeature(@intFromEnum(Target.x86.Feature.f16c));
                features.addFeature(@intFromEnum(Target.x86.Feature.fma4));
                break :blk features;
            },
            else => return error.UnsupportedArch,
        },
    });
    return target;
}

fn addInstallKernelFile(b: *Build, compile_action: *Build.Step.Compile) *Build.Step.InstallArtifact {
    const install = b.addInstallArtifact(compile_action, .{
        .dest_dir = .{
            .override = .prefix, //do not install inside bin subdirectory
        },
    });
    return install;
}

fn addKernelUninstall(b: *Build, install_kernel_action: *Build.Step.InstallArtifact) !*Build.Step.Run {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const kernel_uninstall = b.addSystemCommand(&.{ "rm", "-r" });
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ b.install_prefix, install_kernel_action.dest_sub_path });
    kernel_uninstall.addArg(path);
    return kernel_uninstall;
}

// fn addLimineBuild(b: *Build, target: Build.ResolvedTarget) *Build.Step.Run {
//     const limine = b.dependency("limine", .{});
//     const exe = b.addExecutable(.{
//         .name = "limine",
//         .target = target,
//         .optimize = .ReleaseFast,
//     });
//     exe.addCSourceFile(.{
//         .file = limine.path("limine.c"),
//     });
//     exe.linkLibC();
//     const run = b.addRunArtifact(exe);
//     return run;
// }

fn addBuildIso(b: *Build, kernel: *Build.Step.Compile) *Build.Step.Run {
    const limine = b.dependency("limine", .{});
    const iso_files = b.addWriteFiles();
    _ = iso_files.addCopyFile(kernel.getEmittedBin(), "kernel.elf");
    //_ = iso_prepate_files_action.addCopyFile(.{ .path = "src/boot/limine.cfg" }, "limine.cfg");
    _ = iso_files.addCopyFile(.{ .src_path = .{ .owner = b, .sub_path = "src/boot/limine.conf" } }, "limine.conf");
    _ = iso_files.addCopyFile(limine.path("limine-bios.sys"), "limine-bios.sys");
    _ = iso_files.addCopyFile(limine.path("limine-bios-cd.bin"), "limine-bios-cd.bin");
    _ = iso_files.addCopyFile(limine.path("limine-uefi-cd.bin"), "limine-uefi-cd.bin");
    _ = iso_files.addCopyFile(limine.path("BOOTX64.EFI"), "EFI/BOOT/BOOTX64.EFI");
    _ = iso_files.addCopyFile(limine.path("BOOTIA32.EFI"), "EFI/BOOT/BOOTIA32.EFI");

    const xorriso = b.addSystemCommand(&.{"xorriso"});
    xorriso.addArg("-as");
    xorriso.addArg("mkisofs");
    xorriso.addArg("-b");
    xorriso.addArg("limine-bios-cd.bin");
    xorriso.addArg("-no-emul-boot");
    xorriso.addArg("-boot-load-size");
    xorriso.addArg("4");
    xorriso.addArg("-boot-info-table");
    xorriso.addArg("--efi-boot");
    xorriso.addArg("limine-uefi-cd.bin");
    xorriso.addArg("-efi-boot-part");
    xorriso.addArg("--efi-boot-image");
    xorriso.addArg("--protective-msdos-label");
    xorriso.addDirectoryArg(iso_files.getDirectory());
    xorriso.addArg("-o");
    return xorriso;
}

fn addInstallIso(b: *Build, iso_step: *Build.Step, iso_file: Build.LazyPath) *Build.Step.InstallFile {
    const files = b.addWriteFiles();
    files.step.dependOn(iso_step);
    const path = files.addCopyFile(iso_file, bebok_iso_filename);
    return b.addInstallFile(path, bebok_iso_filename);
}

fn addQemuRun(b: *Build, target: Build.ResolvedTarget, debug: bool, bios_path: []const u8) !*Build.Step.Run {
    const qemu = b.addSystemCommand(&.{switch (target.result.cpu.arch) {
        .x86_64 => "qemu-system-x86_64",
        else => return error.UnsupportedArch,
    }});

    _ = bios_path; //TODO: use it
    switch (target.result.cpu.arch) {
        .x86_64 => {
            qemu.addArgs(&.{
                //"-M", "q35", //for PCIe and NVMe support
                "-M", "q35", //see qemu-system-x86_64 -M help
                "-m", "2G", //Memory size
                "-smp", "1", //one processor only
                // "-cpu", "qemu64,+apic", // TODO: enable 1GB and 2MB pages, for now we turn them off
                //"-enable-kvm", //to be able to use host cpu
                //"-bios", bios_path, //we need ACPI >=2.0
                // "-drive", "if=pflash,format=raw,readonly=on,file=/usr/share/ovmf/OVMF.fd",
            });
            qemu.addArg("-no-reboot");
            qemu.addArg("-cdrom");
            //qemu_iso_action.addArg(try std.fmt.allocPrint(b.allocator, "{s}/{s}", .{b.install_prefix, bebok_iso_filename})); //TODO: can't take installed artifact LazyPAth
            qemu.addArg(try std.fmt.allocPrint(b.allocator, "{s}", .{b.getInstallPath(.prefix, bebok_iso_filename)})); //TODO: can't take installed artifact LazyPAth
            qemu.addArgs(&.{ //PCIe controller
                "-device",
                "pcie-root-port,id=pcie_port0,multifunction=on,bus=pcie.0,addr=0x10",
            });
            qemu.addArgs(&.{ //NVMe controller
                "-device",
                "nvme,drive=drv0,serial=deadbeef,bus=pcie_port0,use-intel-id=on,max_ioqpairs=1",
                //"nvme,serial=1,bus=pcie_port0,use-intel-id=on",
            });
            qemu.addArg("-drive");
            //> TODO: can't take installed artifact LazyPAth, see my issue: https://stackoverflow.com/questions/78499409/buid-system-getting-installed-relative-path
            //qemu_iso_action.addArg(try std.fmt.allocPrint(b.allocator, "file={s}/{s},format=qcow2,if=none,id=drv0", .{b.install_prefix, bebok_disk_img_filename}));
            qemu.addArg(try std.fmt.allocPrint(b.allocator, "file={s},format=raw,if=none,id=drv0", .{b.getInstallPath(.prefix, bebok_disk_img_filename)}));
            //boot from cdrom
            qemu.addArgs(&.{
                "-boot",
                "d",
            }); //boot from cdrom
            qemu.addArgs(&.{ "-debugcon", "stdio" });
            qemu.addArgs(&.{ "--trace", "events=.qemu-events" });
            //qemu_iso_action.addArgs(&.{ "-d", "int,guest_errors,cpu_reset" });
            qemu.addArgs(&.{ "-d", "guest_errors,cpu_reset" });
            //qemu_iso_action.addArgs(&.{ "-D", "qemu-logs.txt" });
            //qemu_iso_action.addArgs(&.{ "-display", "gtk", "-vga", "virtio" });
            qemu.addArgs(&.{ "-display", "gtk", "-vga", "std" });
            if (debug) {
                qemu.addArgs(&.{
                    "-s",
                    "-S",
                });
                qemu.addArgs(&.{ "-d", "int" });
            }
        },
        else => return error.UnsupportedArch,
    }
    return qemu;
}

pub fn build(b: *Build) !void {
    b.enable_qemu = true;

    const build_options = .{
        .arch = b.option(std.Target.Cpu.Arch, "arch", "The architecture to build for") orelse std.Target.Cpu.Arch.x86_64,
        .mem_page_size = b.option(enum(u32) { ps4k = 4096, ps2m = 512 * 4096, ps1g = 1024 * 1024 * 1024 }, "page-size", "Choose the page size: 'ps4k' stands for 4096 bytes, 'ps1m' means 2MB pages, and 'ps1g' is a 1GB page. ") orelse .ps4k,
        .mem_bit_tree_max_levels = b.option(u8, "mem-bit-tree-max-levels", "Maximum number of the bit tree levels to manage memory, calculated as log2(total_memory_in_bytes/page_size_in_bytes)+ 1; defaults to 32") orelse 32,
        .bios_path = b.option([]const u8, "bios-path", "Aboslute path to BIOS file") orelse "/usr/share/qemu/OVMF.fd",
    };

    const kernel_target = try resolveTarget(b, build_options.arch);
    const ut_target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .Debug,
    });

    const limine_zig = b.dependency("limine_zig", .{});
    const limine_zig_mod = limine_zig.module("limine");

    const zigavl = b.dependency("zigavl", .{});
    const zigavl_mod = zigavl.module("zigavl");

    // Comptime options
    const options = b.addOptions();
    options.addOption(u32, "mem_page_size", @intFromEnum(build_options.mem_page_size));
    options.addOption(u8, "mem_bit_tree_max_levels", build_options.mem_bit_tree_max_levels);
    options.addOption(std.SemanticVersion, "kernel_version", kernel_version);

    // Modules start
    const kernel_mod = b.createModule(.{
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/kernel.zig" } },
        .target = kernel_target,
        .optimize = optimize,
        .single_threaded = true,
        .code_model = .kernel,
        .pic = false,
    });
    const kernel_ut_mod = b.createModule(.{
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/kernel.zig" } },
        .target = ut_target,
    });

    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = kernel_mod,
    });

    kernel.setLinkerScript(.{ .src_path = .{ .owner = b, .sub_path = b.fmt("linker-{s}.ld", .{@tagName(kernel_target.result.cpu.arch)}) } });
    kernel.out_filename = "kernel.elf";
    kernel.pie = false;

    const options_mod = options.createModule();
    kernel_mod.addImport("config", options_mod);
    kernel_ut_mod.addImport("config", options_mod);

    kernel_mod.addImport("limine", limine_zig_mod);
    kernel_ut_mod.addImport("limine", limine_zig_mod);

    // Core system modules
    const core_mod = b.addModule("core", .{ .root_source_file = b.path("src/core/mod.zig"), .target = kernel_target });
    const core_ut_mod = b.addModule("core", .{ .root_source_file = b.path("src/core/mod.zig"), .target = ut_target });

    const commons_mod = b.addModule("commons", .{ .root_source_file = b.path("src/commons/mod.zig"), .target = kernel_target });
    const commons_ut_mod = b.addModule("commons", .{ .root_source_file = b.path("src/commons/mod.zig"), .target = ut_target });

    const drivers_mod = b.addModule("drivers", .{ .root_source_file = b.path("src/drivers/mod.zig"), .target = kernel_target });
    const drivers_ut_mod = b.addModule("drivers", .{ .root_source_file = b.path("src/drivers/mod.zig"), .target = ut_target });

    const bus_mod = b.addModule("bus", .{ .root_source_file = b.path("src/bus/mod.zig"), .target = kernel_target });
    const bus_ut_mod = b.addModule("bus", .{ .root_source_file = b.path("src/bus/mod.zig"), .target = ut_target });

    const devices_mod = b.addModule("devices", .{ .root_source_file = b.path("src/devices/mod.zig"), .target = kernel_target });
    const devices_ut_mod = b.addModule("devices", .{ .root_source_file = b.path("src/devices/mod.zig"), .target = ut_target });

    // Memory management modules
    const mem_mod = b.addModule("mem", .{ .root_source_file = b.path("src/mem/mod.zig"), .target = kernel_target });
    const mem_ut_mod = b.addModule("mem", .{ .root_source_file = b.path("src/mem/mod.zig"), .target = ut_target });

    const mm_mod = b.addModule("mm", .{ .root_source_file = b.path("src/modules/mm/mod.zig"), .target = kernel_target });
    const mm_ut_mod = b.addModule("mm", .{ .root_source_file = b.path("src/modules/mm/mod.zig"), .target = ut_target });

    // Filesystem modules
    const fs_mod = b.addModule("fs", .{ .root_source_file = b.path("src/fs/mod.zig"), .target = kernel_target });
    const fs_ut_mod = b.addModule("fs", .{ .root_source_file = b.path("src/fs/mod.zig"), .target = ut_target });

    const ext2_mod = b.addModule("ext2", .{ .root_source_file = b.path("src/modules/fs/ext2/mod.zig"), .target = kernel_target });
    const ext2_ut_mod = b.addModule("ext2", .{ .root_source_file = b.path("src/modules/fs/ext2/mod.zig"), .target = ut_target });

    // Storage modules
    const gpt_mod = b.addModule("gpt", .{ .root_source_file = b.path("src/modules/block/gpt/mod.zig"), .target = kernel_target });
    const gpt_ut_mod = b.addModule("gpt", .{ .root_source_file = b.path("src/modules/block/gpt/mod.zig"), .target = ut_target });

    const nvme_mod = b.addModule("nvme", .{ .root_source_file = b.path("src/modules/block/nvme/mod.zig"), .target = kernel_target });
    const nvme_ut_mod = b.addModule("nvme", .{ .root_source_file = b.path("src/modules/block/nvme/mod.zig"), .target = ut_target });

    // UI modules
    const terminal_mod = b.addModule("terminal", .{ .root_source_file = b.path("src/modules/terminal/mod.zig"), .target = kernel_target });
    const terminal_ut_mod = b.addModule("terminal", .{ .root_source_file = b.path("src/modules/terminal/mod.zig"), .target = ut_target });

    // Zig Language modules
    const lang_mod = b.addModule("lang", .{ .root_source_file = b.path("src/modules/lang/mod.zig"), .target = kernel_target });
    const lang_ut_mod = b.addModule("lang", .{ .root_source_file = b.path("src/modules/lang/mod.zig"), .target = ut_target });

    // Scheduler modules
    const sched_mod = b.addModule("sched", .{ .root_source_file = b.path("src/sched/mod.zig"), .target = kernel_target });
    const sched_ut_mod = b.addModule("sched", .{ .root_source_file = b.path("src/sched/mod.zig"), .target = ut_target });

    // Core module dependencies
    core_mod.addImport("limine", limine_zig_mod);
    core_ut_mod.addImport("limine", limine_zig_mod);

    core_mod.addImport("config", options_mod);
    core_ut_mod.addImport("config", options_mod);

    core_mod.addImport("commons", commons_mod);
    core_ut_mod.addImport("commons", commons_ut_mod);

    // Bus and device dependencies
    bus_mod.addImport("core", core_mod);
    bus_ut_mod.addImport("core", core_ut_mod);

    bus_mod.addImport("devices", devices_mod);
    bus_ut_mod.addImport("devices", devices_ut_mod);

    bus_mod.addImport("drivers", drivers_mod);
    bus_ut_mod.addImport("drivers", drivers_ut_mod);

    drivers_mod.addImport("bus", bus_mod);
    drivers_ut_mod.addImport("bus", bus_ut_mod);

    devices_mod.addImport("bus", bus_mod);
    devices_ut_mod.addImport("bus", bus_ut_mod);

    devices_mod.addImport("gpt", gpt_mod);
    devices_ut_mod.addImport("gpt", gpt_ut_mod);

    devices_mod.addImport("commons", commons_mod);
    devices_ut_mod.addImport("commons", commons_ut_mod);

    devices_mod.addImport("fs", fs_mod);
    devices_ut_mod.addImport("fs", fs_ut_mod);

    devices_ut_mod.addImport("fs", fs_ut_mod);
    devices_ut_mod.addImport("fs", fs_ut_mod);

    devices_mod.addImport("mem", mem_mod);
    devices_ut_mod.addImport("mem", mem_ut_mod);

    // Memory management dependencies
    mem_mod.addImport("limine", limine_zig_mod);
    mem_ut_mod.addImport("limine", limine_zig_mod);

    mem_mod.addImport("core", core_mod);
    mem_ut_mod.addImport("core", core_ut_mod);

    mem_mod.addImport("mm", mm_mod);
    mem_ut_mod.addImport("mm", mm_ut_mod);

    mem_mod.addImport("config", options_mod);
    mem_ut_mod.addImport("config", options_mod);

    mem_mod.addImport("zigavl", zigavl_mod);
    mem_ut_mod.addImport("zigavl", zigavl_mod);

    // Storage dependencies
    gpt_mod.addImport("devices", devices_mod);
    gpt_ut_mod.addImport("devices", devices_ut_mod);

    gpt_mod.addImport("commons", commons_mod);
    gpt_ut_mod.addImport("commons", commons_ut_mod);

    nvme_mod.addImport("drivers", drivers_mod);
    nvme_ut_mod.addImport("drivers", drivers_ut_mod);

    nvme_mod.addImport("core", core_mod);
    nvme_ut_mod.addImport("core", core_ut_mod);

    nvme_mod.addImport("mem", mem_mod);
    nvme_ut_mod.addImport("mem", mem_ut_mod);

    nvme_mod.addImport("bus", bus_mod);
    nvme_ut_mod.addImport("bus", bus_ut_mod);

    nvme_mod.addImport("devices", devices_mod);
    nvme_ut_mod.addImport("devices", devices_ut_mod);

    // Filesystem dependencies
    fs_mod.addImport("bus", bus_mod);
    fs_ut_mod.addImport("bus", bus_ut_mod);

    fs_mod.addImport("devices", devices_mod);
    fs_ut_mod.addImport("devices", devices_ut_mod);
    fs_mod.addImport("lang", lang_mod);
    fs_mod.addImport("sched", sched_mod); //tasks
    fs_mod.addImport("mem", mem_mod);

    ext2_mod.addImport("mem", mem_mod);
    ext2_ut_mod.addImport("mem", mem_ut_mod);

    ext2_mod.addImport("devices", devices_mod);
    ext2_ut_mod.addImport("devices", devices_ut_mod);

    ext2_mod.addImport("fs", fs_mod);
    ext2_ut_mod.addImport("fs", fs_ut_mod);

    ext2_mod.addImport("lang", lang_mod);

    // UI dependencies
    terminal_mod.addImport("limine", limine_zig_mod);
    terminal_ut_mod.addImport("limine", limine_zig_mod);

    // Scheduler dependencies
    sched_mod.addImport("fs", fs_mod);

    // Root module imports
    kernel_mod.addImport("core", core_mod);
    kernel_ut_mod.addImport("core", core_ut_mod);

    kernel_mod.addImport("commons", commons_mod);
    kernel_ut_mod.addImport("commons", commons_ut_mod);

    kernel_mod.addImport("drivers", drivers_mod);
    kernel_ut_mod.addImport("drivers", drivers_ut_mod);

    kernel_mod.addImport("devices", devices_mod);
    kernel_ut_mod.addImport("devices", devices_ut_mod);

    kernel_mod.addImport("bus", bus_mod);
    kernel_ut_mod.addImport("bus", bus_ut_mod);

    kernel_mod.addImport("mm", mm_mod);
    kernel_ut_mod.addImport("mm", mm_ut_mod);

    kernel_mod.addImport("gpt", gpt_mod);
    kernel_ut_mod.addImport("gpt", gpt_ut_mod);

    kernel_mod.addImport("fs", fs_mod);
    kernel_ut_mod.addImport("fs", fs_ut_mod);

    kernel_mod.addImport("mem", mem_mod);
    kernel_ut_mod.addImport("mem", mem_ut_mod);

    kernel_mod.addImport("terminal", terminal_mod);
    kernel_ut_mod.addImport("terminal", terminal_ut_mod);

    kernel_mod.addImport("nvme", nvme_mod);
    kernel_ut_mod.addImport("nvme", nvme_ut_mod);

    kernel_mod.addImport("ext2", ext2_mod);
    kernel_ut_mod.addImport("ext2", ext2_ut_mod);

    kernel_mod.addImport("sched", sched_mod);
    kernel_ut_mod.addImport("sched", sched_ut_mod);

    //Modules end

    const kernel_ins_file = addInstallKernelFile(b, kernel);
    // overwrite standard install
    b.getInstallStep().dependOn(&kernel_ins_file.step);

    const kernel_unins_run = try addKernelUninstall(b, kernel_ins_file);
    // overwrite standard uninstall
    b.getUninstallStep().dependOn(&kernel_unins_run.step);

    //? const limine_run = addLimineBuild(b, kernel_target);

    const iso_run = addBuildIso(b, kernel);
    const iso_run_out = iso_run.addOutputFileArg(bebok_iso_filename);
    const iso_step = b.step("iso", "Build ISO");
    iso_run.step.dependOn(&kernel.step);
    iso_step.dependOn(&iso_run.step);

    //inject limine args
    //? limine_run.addArg("bios-install");
    //? limine_run.addFileArg(iso_run_out);

    const iso_ins_file = addInstallIso(b, &iso_run.step, iso_run_out);
    const iso_ins_step = b.step("iso-install", "Build the ISO");
    iso_ins_file.step.dependOn(iso_step);
    iso_ins_step.dependOn(&iso_ins_file.step);

    const qemu_iso_run = try addQemuRun(b, kernel_target, false, build_options.bios_path); //run with the cached iso file
    const qemu_iso_step = b.step("iso-qemu", "Run the ISO in QEMU");
    qemu_iso_run.step.dependOn(iso_ins_step);
    qemu_iso_step.dependOn(&qemu_iso_run.step);

    // debug mode
    const qemu_iso_debug_run = try addQemuRun(b, kernel_target, true, build_options.bios_path); //run with the cached iso file
    const qemu_iso_debug_step = b.step("iso-qemu-debug", "Run the ISO in QEMU with debug mode enabled");
    qemu_iso_debug_run.step.dependOn(b.getInstallStep()); //debug mode requires a kernel to be installed
    qemu_iso_debug_run.step.dependOn(iso_ins_step);
    qemu_iso_debug_step.dependOn(&qemu_iso_debug_run.step);

    //Unit Test task
    const kernel_ut = b.addTest(.{
        .name = "kernel",
        .root_module = kernel_ut_mod,
    });
    const kernel_ut_run = b.addRunArtifact(kernel_ut);

    const core_ut = b.addTest(.{
        .name = "core",
        .root_module = core_ut_mod,
    });
    const core_ut_run = b.addRunArtifact(core_ut);

    const commons_ut = b.addTest(.{
        .name = "commons",
        .root_module = commons_ut_mod,
    });
    const commons_ut_run = b.addRunArtifact(commons_ut);

    const drivers_ut = b.addTest(.{
        .name = "drivers",
        .root_module = drivers_ut_mod,
    });
    const drivers_ut_run = b.addRunArtifact(drivers_ut);

    const bus_ut = b.addTest(.{
        .name = "bus",
        .root_module = bus_ut_mod,
    });
    const bus_ut_run = b.addRunArtifact(bus_ut);

    const devices_ut = b.addTest(.{
        .name = "devices",
        .root_module = devices_ut_mod,
    });
    const devices_ut_run = b.addRunArtifact(devices_ut);

    const mem_ut = b.addTest(.{
        .name = "mem",
        .root_module = mem_ut_mod,
    });
    const mem_ut_run = b.addRunArtifact(mem_ut);

    const mm_ut = b.addTest(.{
        .name = "mm",
        .root_module = mm_ut_mod,
    });
    const mm_ut_run = b.addRunArtifact(mm_ut);

    const fs_ut = b.addTest(.{
        .name = "fs",
        .root_module = fs_ut_mod,
    });
    const fs_ut_run = b.addRunArtifact(fs_ut);

    const ext2_ut = b.addTest(.{
        .name = "ext2",
        .root_module = ext2_ut_mod,
    });
    const ext2_ut_run = b.addRunArtifact(ext2_ut);

    const gpt_ut = b.addTest(.{
        .name = "gpt",
        .root_module = gpt_ut_mod,
    });
    const gpt_ut_run = b.addRunArtifact(gpt_ut);

    const nvme_ut = b.addTest(.{
        .name = "nvme",
        .root_module = nvme_ut_mod,
    });
    const nvme_ut_run = b.addRunArtifact(nvme_ut);

    const terminal_ut = b.addTest(.{
        .name = "terminal",
        .root_module = terminal_ut_mod,
    });
    const terminal_ut_run = b.addRunArtifact(terminal_ut);

    const lang_ut = b.addTest(.{
        .name = "lang",
        .root_module = lang_ut_mod,
    });
    const lang_ut_run = b.addRunArtifact(lang_ut);

    const sched_ut = b.addTest(.{
        .name = "sched",
        .root_module = sched_ut_mod,
    });
    const sched_ut_run = b.addRunArtifact(sched_ut);

    const ut_step = b.step("unit-tests", "Run unit tests");
    ut_step.dependOn(&kernel_ut_run.step);
    ut_step.dependOn(&core_ut_run.step);
    ut_step.dependOn(&commons_ut_run.step);
    ut_step.dependOn(&drivers_ut_run.step);
    ut_step.dependOn(&bus_ut_run.step);
    ut_step.dependOn(&devices_ut_run.step);
    ut_step.dependOn(&mem_ut_run.step);
    ut_step.dependOn(&mm_ut_run.step);
    ut_step.dependOn(&fs_ut_run.step);
    ut_step.dependOn(&ext2_ut_run.step);
    ut_step.dependOn(&gpt_ut_run.step);
    ut_step.dependOn(&nvme_ut_run.step);
    ut_step.dependOn(&terminal_ut_run.step);
    ut_step.dependOn(&lang_ut_run.step);
    ut_step.dependOn(&sched_ut_run.step);

    b.default_step = iso_step;
}
