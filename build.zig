const std = @import("std");
const builtin = @import("builtin");
const BuildError = error{
    UnsupportedTarget,
    ModuleNotFound,
};

fn resolve_target(b: *std.Build, target_requested: ?[]const u8) !std.Build.ResolvedTarget {
    const target_host = @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.os.tag);
    const target = target_requested orelse target_host;

    const supported_targets = [_][]const u8{
        "aarch64-macos",
        "x86_64-macos",
    };

    var target_supported = false;
    inline for (supported_targets) |supported_target| {
        if (std.mem.eql(u8, supported_target, target))
            target_supported = !target_supported;
    }
    if (!target_supported) {
        std.log.err("unsupported target device : {s}", .{target_requested.?});
        std.log.info("the following are the list of supported architecture", .{});
        inline for (supported_targets) |supported_target| {
            std.log.info("\t> {s}\n", .{supported_target});
        }
        return error.UnsupportedTarget;
    }

    return b.resolveTargetQuery(std.Target.Query{
        .os_tag = builtin.target.os.tag,
        .cpu_arch = builtin.target.cpu.arch,
    });
}

pub fn build(b: *std.Build) !void {
    const options = .{
        .target_requested = b.option([]const u8, "target-os", "os type specification"),
    };

    const target = resolve_target(b, options.target_requested) catch b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "scorpio",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zzz = b.dependency("zzz", .{
        .target = target,
        .optimize = optimize,
    }).module("zzz");

    const tardy = b.dependency("tardy", .{
        .target = target,
        .optimize = optimize,
    }).module("tardy");

    const args_parser = b.dependency("zig-args", .{
        .target = target,
        .optimize = optimize,
    }).module("args");

    const chroma = b.dependency("chroma-logger", .{
        .target = target,
        .optimize = optimize,
    }).module("chroma-logger");

    exe.root_module.addImport("chroma", chroma);
    exe.root_module.addImport("zzz", zzz);
    exe.root_module.addImport("args", args_parser);
    exe.root_module.addImport("tardy", tardy);
    if (target.query.os_tag.? == .linux) {
        exe.root_module.addCMacro("DD_PROF", "1");
        exe.root_module.addIncludePath(b.path("src/ddprof/include"));
        const ddprof = b.addStaticLibrary(.{
            .name = "libdd_profiling",
            .root_source_file = b.path("src/ddprof/lib/libdd_profiling.a"),
            .target = target,
            .optimize = optimize,
        });
        exe.linkLibrary(ddprof);
        exe.linkLibC();
    }

    const build_options = b.addOptions();
    build_options.addOption(std.Target.Os.Tag, "os-tag", target.query.os_tag.?);
    exe.root_module.addOptions("config", build_options);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
