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

/// Main compilation units
/// Add here all modules that should be compiled into the kernel
fn compileKernelAction(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: *Build.Step.Options, limine_zig_mod: *Build.Module, zigavl_mod: *Build.Module) *Build.Step.Compile {
    const compile_kernel_action = b.addExecutable(.{
        .name = "kernel.elf",
        // .root_source_file = .{ .path = "src/kernel.zig" },
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/kernel.zig" } },
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .code_model = .kernel,
        .pic = false, //TODO: check if this is needed
    });

    // Pass options to the code
    compile_kernel_action.root_module.addOptions("config", options);

    compile_kernel_action.root_module.addImport("limine", limine_zig_mod);
    compile_kernel_action.root_module.addImport("zigavl", zigavl_mod);
    //compile_kernel_action.setLinkerScript(.{ .path = b.fmt("linker-{s}.ld", .{@tagName(target.result.cpu.arch)}) });
    compile_kernel_action.setLinkerScript(.{ .src_path = .{ .owner = b, .sub_path = b.fmt("linker-{s}.ld", .{@tagName(target.result.cpu.arch)}) } });
    compile_kernel_action.out_filename = "kernel.elf";
    compile_kernel_action.pie = false; //TODO: ?

    //{Modules
    //const terminal_module = b.addModule("terminal", .{ .root_source_file = .{ .path = "lib/terminal/mod.zig" } });
    const terminal_module = b.addModule("terminal", .{ .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/modules/terminal/mod.zig" } } });
    terminal_module.addImport("limine", limine_zig_mod); //we need limine there
    compile_kernel_action.root_module.addImport("terminal", terminal_module);

    //const utils_module = b.addModule("utils", .{ .root_source_file = .{ .path = "lib/utils/mod.zig" } });
    const utils_module = b.addModule("utils", .{ .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/modules/utils/mod.zig" } } });
    compile_kernel_action.root_module.addImport("utils", utils_module);

    const nvme_module = b.addModule("nvme", .{ .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/modules/block/nvme/mod.zig" } } });
    compile_kernel_action.root_module.addImport("nvme", nvme_module);

    const gpt_module = b.addModule("gpt", .{ .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/modules/block/gpt/mod.zig" } } });
    compile_kernel_action.root_module.addImport("gpt", gpt_module);
    //}Modules

    return compile_kernel_action;
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

fn buildLimineAction(b: *Build) *Build.Step.Run {
    const limine_dep = b.dependency("limine", .{});
    const limine_build_task = b.addExecutable(.{
        .name = "limine",
        .target = b.host,
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

pub fn build(b: *Build) !void {
    b.enable_qemu = true;

    const build_options = .{
        .arch = b.option(std.Target.Cpu.Arch, "arch", "The architecture to build for") orelse b.host.result.cpu.arch,
        .mem_page_size = b.option(enum(u32) { ps4k = 4096, ps2m = 512 * 4096, ps1g = 1024 * 1024 * 1024 }, "page-size", "Choose the page size: 'ps4k' stands for 4096 bytes, 'ps1m' means 2MB pages, and 'ps1g' is a 1GB page. ") orelse .ps4k,
        .mem_bit_tree_max_levels = b.option(u8, "mem-bit-tree-max-levels", "Maximum number of the bit tree levels to manage memory, calculated as log2(total_memory_in_bytes/page_size_in_bytes)+ 1; defaults to 32") orelse 32,
        .bios_path = b.option([]const u8, "bios-path", "Aboslute path to BIOS file") orelse "/usr/share/qemu/OVMF.fd",
    };

    const target = try resolveTarget(b, build_options.arch);

    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe, //tODO: uncomment
        // .preferred_optimize_mode = .Debug,
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

    const compile_kernel_action = compileKernelAction(b, target, optimize, options, limine_zig_mod, zigavl_mod);
    const install_kernel_action = installKernelAction(b, compile_kernel_action);
    const install_kernel_task = &install_kernel_action.step;
    // overwrite standard install
    b.getInstallStep().dependOn(install_kernel_task);

    // overwrite standard uninstall
    const uninstall_kernel_action = try uninstallKernelAction(b, install_kernel_action);
    const uninstall_kernel_task = &uninstall_kernel_action.step;
    b.getUninstallStep().dependOn(uninstall_kernel_task);

    const limine_action = buildLimineAction(b);

    const build_iso_file_action = buildIsoFileAction(b, compile_kernel_action);
    const build_iso_file_action_output = build_iso_file_action.addOutputFileArg(bebok_iso_filename);
    injectLimineStages(limine_action, build_iso_file_action_output);
    const build_iso_file_task = &build_iso_file_action.step;

    const install_iso_file_action = installIsoFileAction(b, build_iso_file_task, build_iso_file_action_output);
    const install_iso_file_task = &install_iso_file_action.step;
    const iso_stage = b.step("iso-install", "Build the ISO");
    iso_stage.dependOn(install_iso_file_task);
    iso_stage.dependOn(install_kernel_task); //to be able to debug in gdb

    const qemu_iso_action = try qemuIsoAction(b, target, false, build_options.bios_path); //run with the cached iso file
    const qemu_iso_task = &qemu_iso_action.step;
    qemu_iso_task.dependOn(install_iso_file_task);
    const qemu_iso_stage = b.step("iso-qemu", "Run the ISO in QEMU");
    qemu_iso_stage.dependOn(qemu_iso_task);

    // debug mode
    const qemu_iso_debug_action = try qemuIsoAction(b, target, true, build_options.bios_path); //run with the cached iso file
    const qemu_iso_debug_task = &qemu_iso_debug_action.step;
    qemu_iso_debug_task.dependOn(install_iso_file_task);
    qemu_iso_debug_task.dependOn(install_kernel_task); //to be able to debug in gdb
    const qemu_iso_debug_stage = b.step("iso-qemu-debug", "Run the ISO in QEMU with debug mode enabled");
    qemu_iso_debug_stage.dependOn(qemu_iso_debug_task);

    b.default_step = iso_stage;
}
