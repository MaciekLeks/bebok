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

// fn compileKernelAction(
//     b: *Build,
//     target: Build.ResolvedTarget,
//     optimize: std.builtin.OptimizeMode,
//     options: *Build.Step.Options,
//     limine_zig_mod: *Build.Module,
//     zigavl_mod: *Build.Module,
// ) *Build.Step.Compile {
//     const compile_kernel_action = b.addExecutable(.{
//         .name = "kernel.elf",
//         .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/kernel.zig" } },
//         .target = target,
//         .optimize = optimize,
//         .single_threaded = true,
//         .code_model = .kernel,
//         .pic = false,
//     });
//
//     // Linker configuration
//     compile_kernel_action.setLinkerScript(.{ .src_path = .{ .owner = b, .sub_path = b.fmt("linker-{s}.ld", .{@tagName(target.result.cpu.arch)}) } });
//     compile_kernel_action.out_filename = "kernel.elf";
//     compile_kernel_action.pie = false;
//
//     configureDependencies(b, compile_kernel_action, options, limine_zig_mod, zigavl_mod);
//     return compile_kernel_action;
// }
//
fn configureDependencies(
    b: *Build,
    compile_action: *Build.Step.Compile,
    options: *Build.Step.Options,
    limine_zig_mod: *Build.Module,
    zigavl_mod: *Build.Module,
) void {
    // Base modules setup
    const options_module = options.createModule();
    compile_action.root_module.addImport("config", options_module);
    compile_action.root_module.addImport("limine", limine_zig_mod);

    // Core system modules
    const core_module = b.addModule("core", .{ .root_source_file = b.path("src/core/mod.zig") });
    const commons_module = b.addModule("commons", .{ .root_source_file = b.path("src/commons/mod.zig") });
    const drivers_module = b.addModule("drivers", .{ .root_source_file = b.path("src/drivers/mod.zig") });
    const bus_module = b.addModule("bus", .{ .root_source_file = b.path("src/bus/mod.zig") });
    const devices_module = b.addModule("devices", .{ .root_source_file = b.path("src/devices/mod.zig") });

    // Memory management modules
    const mem_module = b.addModule("mem", .{ .root_source_file = b.path("src/mem/mod.zig") });
    const utils_module = b.addModule("mm", .{ .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/modules/mm/mod.zig" } } });

    // Filesystem modules
    const fs_module = b.addModule("fs", .{ .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/fs/mod.zig" } } });
    const ext2_module = b.addModule("ext2", .{ .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/modules/fs/ext2/mod.zig" } } });

    // Storage modules
    const gpt_module = b.addModule("gpt", .{ .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/modules/block/gpt/mod.zig" } } });
    const nvme_module = b.addModule("nvme", .{ .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/modules/block/nvme/mod.zig" } } });

    // UI modules
    const terminal_module = b.addModule("terminal", .{ .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/modules/terminal/mod.zig" } } });

    // Core module dependencies
    core_module.addImport("limine", limine_zig_mod);
    core_module.addImport("config", options_module);
    core_module.addImport("commons", commons_module);

    // Bus and device dependencies
    bus_module.addImport("core", core_module);
    bus_module.addImport("devices", devices_module);
    bus_module.addImport("drivers", drivers_module);
    drivers_module.addImport("bus", bus_module);
    devices_module.addImport("bus", bus_module);
    devices_module.addImport("gpt", gpt_module);
    devices_module.addImport("commons", commons_module);
    devices_module.addImport("fs", fs_module);
    devices_module.addImport("mem", mem_module);

    // Memory management dependencies
    mem_module.addImport("limine", limine_zig_mod);
    mem_module.addImport("core", core_module);
    mem_module.addImport("mm", utils_module);
    mem_module.addImport("config", options_module);
    mem_module.addImport("zigavl", zigavl_mod);

    // Storage dependencies
    gpt_module.addImport("devices", devices_module);
    gpt_module.addImport("commons", commons_module);
    nvme_module.addImport("drivers", drivers_module);
    nvme_module.addImport("core", core_module);
    nvme_module.addImport("mem", mem_module);
    nvme_module.addImport("bus", bus_module);
    nvme_module.addImport("devices", devices_module);

    // Filesystem dependencies
    fs_module.addImport("bus", bus_module);
    fs_module.addImport("devices", devices_module);
    ext2_module.addImport("mem", mem_module);
    ext2_module.addImport("devices", devices_module);
    ext2_module.addImport("fs", fs_module);

    // UI dependencies
    terminal_module.addImport("limine", limine_zig_mod);

    // Root module imports
    compile_action.root_module.addImport("core", core_module);
    compile_action.root_module.addImport("commons", commons_module);
    compile_action.root_module.addImport("drivers", drivers_module);
    compile_action.root_module.addImport("devices", devices_module);
    compile_action.root_module.addImport("bus", bus_module);
    compile_action.root_module.addImport("mm", utils_module);
    compile_action.root_module.addImport("gpt", gpt_module);
    compile_action.root_module.addImport("fs", fs_module);
    compile_action.root_module.addImport("mem", mem_module);
    compile_action.root_module.addImport("terminal", terminal_module);
    compile_action.root_module.addImport("nvme", nvme_module);
    compile_action.root_module.addImport("ext2", ext2_module);
}

fn installKernelAction(b: *Build, compile_action: *Build.Step.Compile) *Build.Step.InstallArtifact {
    const install_kernel_action = b.addInstallArtifact(compile_action, .{
        .dest_dir = .{
            .override = .prefix, //do not install inside bin subdirectory
        },
    });
    return install_kernel_action;
}

fn uninstallKernelAction(b: *Build, install_kernel_action: *Build.Step.InstallArtifact) !*Build.Step.Run {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const uninstall_kernel_action = b.addSystemCommand(&.{ "rm", "-r" });
    const install_abs_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ b.install_prefix, install_kernel_action.dest_sub_path });
    uninstall_kernel_action.addArg(install_abs_path);
    return uninstall_kernel_action;
}

fn buildLimineAction(b: *Build, target: Build.ResolvedTarget) *Build.Step.Run {
    const limine_dep = b.dependency("limine", .{});
    const limine_build_task = b.addExecutable(.{
        .name = "limine",
        .target = target,
        .optimize = .ReleaseFast,
    });
    limine_build_task.addCSourceFile(.{
        .file = limine_dep.path("limine.c"),
    });
    limine_build_task.linkLibC();
    const limine_run_action = b.addRunArtifact(limine_build_task);
    return limine_run_action;
}

fn buildIsoFileAction(b: *Build, compile_kernel_action: *Build.Step.Compile) *Build.Step.Run {
    const limine_dep = b.dependency("limine", .{});
    const iso_prepate_files_action = b.addWriteFiles();
    _ = iso_prepate_files_action.addCopyFile(compile_kernel_action.getEmittedBin(), "kernel.elf");
    //_ = iso_prepate_files_action.addCopyFile(.{ .path = "src/boot/limine.cfg" }, "limine.cfg");
    _ = iso_prepate_files_action.addCopyFile(.{ .src_path = .{ .owner = b, .sub_path = "src/boot/limine.conf" } }, "limine.conf");
    _ = iso_prepate_files_action.addCopyFile(limine_dep.path("limine-bios.sys"), "limine-bios.sys");
    _ = iso_prepate_files_action.addCopyFile(limine_dep.path("limine-bios-cd.bin"), "limine-bios-cd.bin");
    _ = iso_prepate_files_action.addCopyFile(limine_dep.path("limine-uefi-cd.bin"), "limine-uefi-cd.bin");
    _ = iso_prepate_files_action.addCopyFile(limine_dep.path("BOOTX64.EFI"), "EFI/BOOT/BOOTX64.EFI");
    _ = iso_prepate_files_action.addCopyFile(limine_dep.path("BOOTIA32.EFI"), "EFI/BOOT/BOOTIA32.EFI");

    const iso_build_action = b.addSystemCommand(&.{"xorriso"});
    iso_build_action.addArg("-as");
    iso_build_action.addArg("mkisofs");
    iso_build_action.addArg("-b");
    iso_build_action.addArg("limine-bios-cd.bin");
    iso_build_action.addArg("-no-emul-boot");
    iso_build_action.addArg("-boot-load-size");
    iso_build_action.addArg("4");
    iso_build_action.addArg("-boot-info-table");
    iso_build_action.addArg("--efi-boot");
    iso_build_action.addArg("limine-uefi-cd.bin");
    iso_build_action.addArg("-efi-boot-part");
    iso_build_action.addArg("--efi-boot-image");
    iso_build_action.addArg("--protective-msdos-label");
    iso_build_action.addDirectoryArg(iso_prepate_files_action.getDirectory());
    iso_build_action.addArg("-o");
    return iso_build_action;
}

fn injectLimineStages(limine_run_action: *Build.Step.Run, iso_file: Build.LazyPath) void {
    limine_run_action.addArg("bios-install");
    limine_run_action.addFileArg(iso_file);
}

fn installIsoFileAction(b: *Build, iso_build_task: *Build.Step, iso_file: Build.LazyPath) *Build.Step.InstallFile {
    const copy_iso_task = b.addWriteFiles();
    copy_iso_task.step.dependOn(iso_build_task);
    const iso_artifact_path = copy_iso_task.addCopyFile(iso_file, bebok_iso_filename);
    return b.addInstallFile(iso_artifact_path, bebok_iso_filename);
}

fn qemuIsoAction(b: *Build, target: Build.ResolvedTarget, debug: bool, bios_path: []const u8) !*Build.Step.Run {
    const qemu_iso_action = b.addSystemCommand(&.{switch (target.result.cpu.arch) {
        .x86_64 => "qemu-system-x86_64",
        else => return error.UnsupportedArch,
    }});

    _ = bios_path; //TODO: use it
    switch (target.result.cpu.arch) {
        .x86_64 => {
            qemu_iso_action.addArgs(&.{
                //"-M", "q35", //for PCIe and NVMe support
                "-M", "q35", //see qemu-system-x86_64 -M help
                "-m", "2G", //Memory size
                "-smp", "1", //one processor only
                // "-cpu", "qemu64,+apic", // TODO: enable 1GB and 2MB pages, for now we turn them off
                //"-enable-kvm", //to be able to use host cpu
                //"-bios", bios_path, //we need ACPI >=2.0
                // "-drive", "if=pflash,format=raw,readonly=on,file=/usr/share/ovmf/OVMF.fd",
            });
            qemu_iso_action.addArg("-no-reboot");
            qemu_iso_action.addArg("-cdrom");
            //qemu_iso_action.addArg(try std.fmt.allocPrint(b.allocator, "{s}/{s}", .{b.install_prefix, bebok_iso_filename})); //TODO: can't take installed artifact LazyPAth
            qemu_iso_action.addArg(try std.fmt.allocPrint(b.allocator, "{s}", .{b.getInstallPath(.prefix, bebok_iso_filename)})); //TODO: can't take installed artifact LazyPAth
            qemu_iso_action.addArgs(&.{ //PCIe controller
                "-device",
                "pcie-root-port,id=pcie_port0,multifunction=on,bus=pcie.0,addr=0x10",
            });
            qemu_iso_action.addArgs(&.{ //NVMe controller
                "-device",
                "nvme,drive=drv0,serial=deadbeef,bus=pcie_port0,use-intel-id=on,max_ioqpairs=1",
                //"nvme,serial=1,bus=pcie_port0,use-intel-id=on",
            });
            qemu_iso_action.addArg("-drive");
            //> TODO: can't take installed artifact LazyPAth, see my issue: https://stackoverflow.com/questions/78499409/buid-system-getting-installed-relative-path
            //qemu_iso_action.addArg(try std.fmt.allocPrint(b.allocator, "file={s}/{s},format=qcow2,if=none,id=drv0", .{b.install_prefix, bebok_disk_img_filename}));
            qemu_iso_action.addArg(try std.fmt.allocPrint(b.allocator, "file={s},format=raw,if=none,id=drv0", .{b.getInstallPath(.prefix, bebok_disk_img_filename)}));
            //boot from cdrom
            qemu_iso_action.addArgs(&.{
                "-boot",
                "d",
            }); //boot from cdrom
            qemu_iso_action.addArgs(&.{ "-debugcon", "stdio" });
            qemu_iso_action.addArgs(&.{ "--trace", "events=.qemu-events" });
            //qemu_iso_action.addArgs(&.{ "-d", "int,guest_errors,cpu_reset" });
            qemu_iso_action.addArgs(&.{ "-d", "guest_errors,cpu_reset" });
            //qemu_iso_action.addArgs(&.{ "-D", "qemu-logs.txt" });
            //qemu_iso_action.addArgs(&.{ "-display", "gtk", "-vga", "virtio" });
            qemu_iso_action.addArgs(&.{ "-display", "gtk", "-vga", "std" });
            if (debug) {
                qemu_iso_action.addArgs(&.{
                    "-s",
                    "-S",
                });
                qemu_iso_action.addArgs(&.{ "-d", "int" });
            }
        },
        else => return error.UnsupportedArch,
    }
    return qemu_iso_action;
}

fn testTask(b: *Build, options: *Build.Step.Options, limine_zig_mod: *Build.Module, zigavl_mod: *Build.Module) *Build.Step.Compile {
    //const target = b.standardTargetOptions(.{});
    const compile_test_action = b.addTest(.{
        .name = "unit-tests",
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/kernel_test.zig" } },
        //  .target = target,
    });

    configureDependencies(b, compile_test_action, options, limine_zig_mod, zigavl_mod);

    const run_test_action = b.addRunArtifact(compile_test_action);
    const run_test_task = b.step("tests", "Run unit tests");
    run_test_task.dependOn(&run_test_action.step);

    const install_test_action = b.addInstallArtifact(compile_test_action, .{
        .dest_dir = .{
            .override = .prefix, //do not install inside bin subdirectory
        },
    }); //instal an exe for debugging
    b.getInstallStep().dependOn(&install_test_action.step);
    const install_test_task = b.step("tests-install", "Install unit tests");
    install_test_task.dependOn(&install_test_action.step);

    return compile_test_action;
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
    const test_target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .Debug,
    });

    const limine_zig_dep = b.dependency("limine_zig", .{});
    const limine_zig_mod = limine_zig_dep.module("limine");

    const zigavl_dep = b.dependency("zigavl", .{});
    const zigavl_mod = zigavl_dep.module("zigavl");

    // Comptime options
    const options = b.addOptions();
    options.addOption(u32, "mem_page_size", @intFromEnum(build_options.mem_page_size));
    options.addOption(u8, "mem_bit_tree_max_levels", build_options.mem_bit_tree_max_levels);
    options.addOption(std.SemanticVersion, "kernel_version", kernel_version);

    ////////////{
    // Root module setup
    const kernel_mod = b.createModule(.{
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/kernel.zig" } },
        .target = kernel_target,
        .optimize = optimize,
        .single_threaded = true,
        .code_model = .kernel,
        .pic = false,
    });
    const kernel_ut_mod = b.createModule(.{
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/kernel_ut.zig" } },
        .target = test_target,
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
    kernel_mod.addImport("limine", limine_zig_mod);

    // Core system modules
    const core_mod = b.addModule("core", .{ .root_source_file = b.path("src/core/mod.zig"), .target = kernel_target });
    const core_ut_mod = b.addModule("core", .{ .root_source_file = b.path("src/core/mod_ut.zig"), .target = test_target });

    const commons_mod = b.addModule("commons", .{ .root_source_file = b.path("src/commons/mod.zig"), .target = kernel_target });
    const commons_ut_mod = b.addModule("commons", .{ .root_source_file = b.path("src/commons/mod_ut.zig"), .target = test_target });

    const drivers_mod = b.addModule("drivers", .{ .root_source_file = b.path("src/drivers/mod.zig"), .target = kernel_target });
    const drivers_ut_mod = b.addModule("drivers", .{ .root_source_file = b.path("src/drivers/mod_ut.zig"), .target = test_target });

    const bus_mod = b.addModule("bus", .{ .root_source_file = b.path("src/bus/mod.zig"), .target = kernel_target });
    const bus_ut_mod = b.addModule("bus", .{ .root_source_file = b.path("src/bus/mod_ut.zig"), .target = test_target });

    const devices_mod = b.addModule("devices", .{ .root_source_file = b.path("src/devices/mod.zig"), .target = kernel_target });
    const devices_ut_mod = b.addModule("devices", .{ .root_source_file = b.path("src/devices/mod_ut.zig"), .target = test_target });

    // Memory management modules
    const mem_mod = b.addModule("mem", .{ .root_source_file = b.path("src/mem/mod.zig"), .target = kernel_target });
    const mem_ut_mod = b.addModule("mem", .{ .root_source_file = b.path("src/mem/mod_ut.zig"), .target = test_target });

    const utils_mod = b.addModule("mm", .{ .root_source_file = b.path("src/modules/mm/mod.zig"), .target = kernel_target });
    const utils_ut_mod = b.addModule("mm", .{ .root_source_file = b.path("src/modules/mm/mod_ut.zig"), .target = test_target });

    // Filesystem modules
    const fs_mod = b.addModule("fs", .{ .root_source_file = b.path("src/fs/mod.zig"), .target = kernel_target });
    const fs_ut_mod = b.addModule("fs", .{ .root_source_file = b.path("src/fs/mod_ut.zig"), .target = test_target });

    const ext2_mod = b.addModule("ext2", .{ .root_source_file = b.path("src/modules/fs/ext2/mod.zig"), .target = kernel_target });
    const ext2_ut_mod = b.addModule("ext2", .{ .root_source_file = b.path("src/modules/fs/ext2/mod_ut.zig"), .target = test_target });

    // Storage modules
    const gpt_mod = b.addModule("gpt", .{ .root_source_file = b.path("src/modules/block/gpt/mod.zig"), .target = kernel_target });
    const gpt_ut_mod = b.addModule("gpt", .{ .root_source_file = b.path("src/modules/block/gpt/mod_ut.zig"), .target = test_target });

    const nvme_mod = b.addModule("nvme", .{ .root_source_file = b.path("src/modules/block/nvme/mod.zig"), .target = kernel_target });
    const nvme_ut_mod = b.addModule("nvme", .{ .root_source_file = b.path("src/modules/block/nvme/mod_ut.zig"), .target = test_target });

    // UI modules
    const terminal_mod = b.addModule("terminal", .{ .root_source_file = b.path("src/modules/terminal/mod.zig"), .target = kernel_target });
    const terminal_ut_mod = b.addModule("terminal", .{ .root_source_file = b.path("src/modules/terminal/mod_ut.zig"), .target = test_target });

    // Core module dependencies
    core_mod.addImport("limine", limine_zig_mod);
    core_mod.addImport("config", options_mod);
    core_mod.addImport("commons", commons_mod);

    // Bus and device dependencies
    bus_mod.addImport("core", core_mod);
    bus_mod.addImport("devices", devices_mod);
    bus_mod.addImport("drivers", drivers_mod);
    drivers_mod.addImport("bus", bus_mod);
    devices_mod.addImport("bus", bus_mod);
    devices_mod.addImport("gpt", gpt_mod);
    devices_mod.addImport("commons", commons_mod);
    devices_mod.addImport("fs", fs_mod);
    devices_mod.addImport("mem", mem_mod);

    // Memory management dependencies
    mem_mod.addImport("limine", limine_zig_mod);
    mem_mod.addImport("core", core_mod);
    mem_mod.addImport("mm", utils_mod);
    mem_mod.addImport("config", options_mod);
    mem_mod.addImport("zigavl", zigavl_mod);

    // Storage dependencies
    gpt_mod.addImport("devices", devices_mod);
    gpt_mod.addImport("commons", commons_mod);
    nvme_mod.addImport("drivers", drivers_mod);
    nvme_mod.addImport("core", core_mod);
    nvme_mod.addImport("mem", mem_mod);
    nvme_mod.addImport("bus", bus_mod);
    nvme_mod.addImport("devices", devices_mod);

    // Filesystem dependencies
    fs_mod.addImport("bus", bus_mod);
    fs_mod.addImport("devices", devices_mod);
    ext2_mod.addImport("mem", mem_mod);
    ext2_mod.addImport("devices", devices_mod);
    ext2_mod.addImport("fs", fs_mod);

    // UI dependencies
    terminal_mod.addImport("limine", limine_zig_mod);

    // Root module imports
    kernel_mod.addImport("core", core_mod);
    kernel_mod.addImport("commons", commons_mod);
    kernel_mod.addImport("drivers", drivers_mod);
    kernel_mod.addImport("devices", devices_mod);
    kernel_mod.addImport("bus", bus_mod);
    kernel_mod.addImport("mm", utils_mod);
    kernel_mod.addImport("gpt", gpt_mod);
    kernel_mod.addImport("fs", fs_mod);
    kernel_mod.addImport("mem", mem_mod);
    kernel_mod.addImport("terminal", terminal_mod);
    kernel_mod.addImport("nvme", nvme_mod);
    kernel_mod.addImport("ext2", ext2_mod);
    /////////////}

    //const compile_kernel_action = compileKernelAction(b, target, optimize, options, limine_zig_mod, zigavl_mod);
    const install_kernel_action = installKernelAction(b, kernel);
    const install_kernel_task = &install_kernel_action.step;
    // overwrite standard install
    b.getInstallStep().dependOn(install_kernel_task);

    // overwrite standard uninstall
    const uninstall_kernel_action = try uninstallKernelAction(b, install_kernel_action);
    const uninstall_kernel_task = &uninstall_kernel_action.step;
    b.getUninstallStep().dependOn(uninstall_kernel_task);

    const limine_action = buildLimineAction(b, kernel_target);

    const build_iso_file_action = buildIsoFileAction(b, kernel);
    const build_iso_file_action_output = build_iso_file_action.addOutputFileArg(bebok_iso_filename);
    injectLimineStages(limine_action, build_iso_file_action_output);
    const build_iso_file_task = &build_iso_file_action.step;

    const install_iso_file_action = installIsoFileAction(b, build_iso_file_task, build_iso_file_action_output);
    const install_iso_file_task = &install_iso_file_action.step;
    const iso_stage = b.step("iso-install", "Build the ISO");
    iso_stage.dependOn(install_iso_file_task);
    iso_stage.dependOn(install_kernel_task); //to be able to debug in gdb

    const qemu_iso_action = try qemuIsoAction(b, kernel_target, false, build_options.bios_path); //run with the cached iso file
    const qemu_iso_task = &qemu_iso_action.step;
    qemu_iso_task.dependOn(install_iso_file_task);
    const qemu_iso_stage = b.step("iso-qemu", "Run the ISO in QEMU");
    qemu_iso_stage.dependOn(qemu_iso_task);

    // debug mode
    const qemu_iso_debug_action = try qemuIsoAction(b, kernel_target, true, build_options.bios_path); //run with the cached iso file
    const qemu_iso_debug_task = &qemu_iso_debug_action.step;
    qemu_iso_debug_task.dependOn(install_iso_file_task);
    qemu_iso_debug_task.dependOn(install_kernel_task); //to be able to debug in gdb
    const qemu_iso_debug_stage = b.step("iso-qemu-debug", "Run the ISO in QEMU with debug mode enabled");
    qemu_iso_debug_stage.dependOn(qemu_iso_debug_task);

    //Unit Test task
    const kernel_ut = b.addTest(.{
        .root_module = kernel_ut_mod,
    });
    const kernel_ut_run = b.addRunArtifact(kernel_ut);

    const core_ut = b.addTest(.{
        .root_module = core_ut_mod,
    });
    const core_ut_run = b.addRunArtifact(core_ut);

    const commons_ut = b.addTest(.{
        .root_module = commons_ut_mod,
    });
    const commons_ut_run = b.addRunArtifact(commons_ut);

    const drivers_ut = b.addTest(.{
        .root_module = drivers_ut_mod,
    });
    const drivers_ut_run = b.addRunArtifact(drivers_ut);

    const bus_ut = b.addTest(.{
        .root_module = bus_ut_mod,
    });
    const bus_ut_run = b.addRunArtifact(bus_ut);

    const devices_ut = b.addTest(.{
        .root_module = devices_ut_mod,
    });
    const devices_ut_run = b.addRunArtifact(devices_ut);

    const mem_ut = b.addTest(.{
        .root_module = mem_ut_mod,
    });
    const mem_ut_run = b.addRunArtifact(mem_ut);

    const utils_ut = b.addTest(.{
        .root_module = utils_ut_mod,
    });
    const utils_ut_run = b.addRunArtifact(utils_ut);

    const fs_ut = b.addTest(.{
        .root_module = fs_ut_mod,
    });
    const fs_ut_run = b.addRunArtifact(fs_ut);

    const ext2_ut = b.addTest(.{
        .root_module = ext2_ut_mod,
    });
    const ext2_ut_run = b.addRunArtifact(ext2_ut);

    const gpt_ut = b.addTest(.{
        .root_module = gpt_ut_mod,
    });
    const gpt_ut_run = b.addRunArtifact(gpt_ut);

    const nvme_ut = b.addTest(.{
        .root_module = nvme_ut_mod,
    });
    const nvme_ut_run = b.addRunArtifact(nvme_ut);

    const terminal_ut = b.addTest(.{
        .root_module = terminal_ut_mod,
    });
    const terminal_ut_run = b.addRunArtifact(terminal_ut);

    const ut_step = b.step("unit-tests", "Run unit tests");
    ut_step.dependOn(&kernel_ut_run.step);
    ut_step.dependOn(&core_ut_run.step);
    ut_step.dependOn(&commons_ut_run.step);
    ut_step.dependOn(&drivers_ut_run.step);
    ut_step.dependOn(&bus_ut_run.step);
    ut_step.dependOn(&devices_ut_run.step);
    ut_step.dependOn(&mem_ut_run.step);
    ut_step.dependOn(&utils_ut_run.step);
    ut_step.dependOn(&fs_ut_run.step);
    ut_step.dependOn(&ext2_ut_run.step);
    ut_step.dependOn(&gpt_ut_run.step);
    ut_step.dependOn(&nvme_ut_run.step);
    ut_step.dependOn(&terminal_ut_run.step);

    b.default_step = iso_stage;
}
