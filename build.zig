const zstd = @import("std");
const builtin = @import("builtin");
const build_zon = @import("build.zig.zon");

const BuildError = error{
    UnsupportedTarget,
    ModuleNotFound,
};

const ModuleImport = zstd.Build.Module.Import;

fn CompileImportCount(comptime T: type) usize {
    comptime var count: usize = 0;
    for (@typeInfo(T).@"struct".fields) |field| {
        const FieldType = field.type;
        if (@typeInfo(FieldType) == .pointer) {
            const ChildType = @typeInfo(FieldType).pointer.child;
            if (ChildType == zstd.Build.Module) count += 1;
        }
    }
    return count;
}

const LibraryModules = struct {
    pub const import_count = CompileImportCount(@This());

    libraries: *zstd.Build.Module,
    common: *zstd.Build.Module,

    fn imports(self: LibraryModules) [import_count]ModuleImport {
        return .{
            .{ .name = "libraries", .module = self.libraries },
            .{ .name = "common", .module = self.common },
        };
    }
};

const DependencyModules = struct {
    pub const import_count = CompileImportCount(@This());

    chroma: *zstd.Build.Module,
    zap: *zstd.Build.Module,
    pg: *zstd.Build.Module,

    fn imports(self: DependencyModules) [import_count]ModuleImport {
        return .{
            .{ .name = "chroma", .module = self.chroma },
            .{ .name = "zap", .module = self.zap },
            .{ .name = "pg", .module = self.pg },
        };
    }
};

/// Expose static build metadata (currently the project name, read from
/// `build.zig.zon`) to source code as an importable `build_info` module.
fn buildInfoModule(b: *zstd.Build) *zstd.Build.Module {
    const options = b.addOptions();
    options.addOption([]const u8, "project_name", @tagName(build_zon.name));
    return options.createModule();
}

fn buildLibraries(
    b: *zstd.Build,
    target: zstd.Build.ResolvedTarget,
    optimize: zstd.builtin.OptimizeMode,
    build_info: *zstd.Build.Module,
    zap: *zstd.Build.Module,
) LibraryModules {
    const common = b.addModule("common", .{
        .root_source_file = b.path("common/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    return .{
        .common = common,
        .libraries = blk: {
            const libraries_mod = b.addModule("libraries", .{
                .root_source_file = b.path("libraries/root.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "build_info", .module = build_info },
                    .{ .name = "common", .module = common },
                    .{ .name = "zap", .module = zap },
                },
                .link_libc = true,
            });
            break :blk libraries_mod;
        },
    };
}

fn buildDependencies(
    b: *zstd.Build,
    target: zstd.Build.ResolvedTarget,
    optimize: zstd.builtin.OptimizeMode,
) DependencyModules {
    return .{
        .chroma = b.dependency(
            "chroma_logger",
            .{
                .target = target,
                .optimize = optimize,
            },
        ).module("chroma-logger"),
        .zap = b.dependency(
            "zap",
            .{
                .target = target,
                .optimize = optimize,
                .openssl = false,
            },
        ).module("zap"),
        .pg = b.dependency("pg", .{
            .target = target,
            .optimize = optimize,
        }).module("pg"),
    };
}

fn moduleImports(
    libraries: LibraryModules,
    dependencies: DependencyModules,
) [LibraryModules.import_count + DependencyModules.import_count]ModuleImport {
    const library_imports = libraries.imports();
    const dependency_imports = dependencies.imports();
    var imports: [LibraryModules.import_count + DependencyModules.import_count]ModuleImport = undefined;
    @memcpy(imports[0..library_imports.len], &library_imports);
    @memcpy(imports[library_imports.len..], &dependency_imports);
    return imports;
}

fn resolve_target(b: *zstd.Build, target_requested: ?[]const u8) !zstd.Build.ResolvedTarget {
    const target_host = @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.os.tag);
    const target = target_requested orelse target_host;

    const supported_targets = [_][]const u8{ "aarch64-macos", "x86_64-macos", "linux" };

    var target_supported = false;
    inline for (supported_targets) |supported_target| {
        if (zstd.mem.eql(u8, supported_target, target))
            target_supported = !target_supported;
    }
    if (!target_supported) {
        zstd.log.err("unsupported target device : {s}", .{target_requested.?});
        zstd.log.info("the following are the list of supported architecture", .{});
        inline for (supported_targets) |supported_target| {
            zstd.log.info("\t> {s}\n", .{supported_target});
        }
        return error.UnsupportedTarget;
    }

    return b.resolveTargetQuery(zstd.Target.Query{
        .os_tag = builtin.target.os.tag,
        .cpu_arch = builtin.target.cpu.arch,
    });
}

pub fn build(b: *zstd.Build) !void {
    const executable_name = b.option(
        []const u8,
        "executable-name",
        "The name of the executable",
    ) orelse "scorpio";
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "A comma-separated list of test filters to run",
    ) orelse &[0][]const u8{};

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_info = buildInfoModule(b);
    const dependencies = buildDependencies(b, target, optimize);
    const libraries = buildLibraries(
        b,
        target,
        optimize,
        build_info,
        dependencies.zap,
    );
    const imports = moduleImports(libraries, dependencies);

    const exe = b.addExecutable(.{
        .name = executable_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    });
    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    const pack_exe = b.addExecutable(.{
        .name = "pack-blog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pack_entry.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    });
    pack_exe.root_module.link_libc = true;
    b.installArtifact(pack_exe);
    const pack_cmd = b.addRunArtifact(pack_exe);
    pack_cmd.has_side_effects = true;
    pack_cmd.setCwd(b.path("."));
    const pack_step = b.step("pack", "Process media, pack blog markdown, upload changed chunks");
    pack_step.dependOn(&pack_cmd.step);

    const prerun_exe = b.addExecutable(.{
        .name = "prerun",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/prerun_entry.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    });
    prerun_exe.root_module.link_libc = true;
    b.installArtifact(prerun_exe);
    const prerun_cmd = b.addRunArtifact(prerun_exe);
    prerun_cmd.has_side_effects = true;
    prerun_cmd.setCwd(b.path("."));
    prerun_cmd.step.dependOn(pack_step);
    const prerun_step = b.step("prerun", "Apply SQL scripts and upsert blog rows from manifest");
    prerun_step.dependOn(&prerun_cmd.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.has_side_effects = true;
    run_cmd.setCwd(b.path("."));
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.step.dependOn(prerun_step);

    const run_step = b.step("run", "Run the app (after prerun)");
    run_step.dependOn(&run_cmd.step);

    const libraries_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libraries/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_info", .module = build_info },
                .{ .name = "common", .module = libraries.common },
                .{ .name = "zap", .module = dependencies.zap },
            },
        }),
        .filters = test_filters,
    });

    libraries_unit_tests.root_module.link_libc = true;
    const run_libraries_unit_tests = b.addRunArtifact(libraries_unit_tests);

    const router_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libraries/router/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zap", .module = dependencies.zap },
            },
        }),
    });
    const run_router_unit_tests = b.addRunArtifact(router_unit_tests);

    const common_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("common/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_common_unit_tests = b.addRunArtifact(common_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    });
    exe_unit_tests.root_module.link_libc = true;
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_common_unit_tests.step);
    test_step.dependOn(&run_router_unit_tests.step);
    test_step.dependOn(&run_libraries_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
