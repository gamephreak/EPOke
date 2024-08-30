const std = @import("std");
const builtin = @import("builtin");

const pkmn = @import("node_modules/@pkmn/engine/build.zig");

const CompileStep = if (@hasDecl(std.Build, "Step"))
    std.Build.Step.Compile
else
    std.Build.CompileStep;
const has_path = @hasField(std.Build.LazyPath, "path");
const root_module = @hasField(CompileStep, "root_module");

const getenv = if (@hasDecl(std, "posix")) std.posix.getenv else std.os.getenv;

pub fn build(b: *std.Build) !void {
    const release = if (getenv("DEBUG_PKMN_ENGINE")) |_| false else true;
    const fast = try std.SemanticVersion.parse("0.12.0-dev.866+3a47bc715");
    if (release and fast.order(builtin.zig_version) == .lt) {
        std.log.warn("Release builds are ~10-20% slower than before Zig " ++
            "v0.12.0-dev.866+3a47bc715 due to ziglang/zig#17768", .{});
    }
    const target = if (@hasDecl(std.Build, "resolveTargetQuery"))
        b.resolveTargetQuery(.{})
    else
        std.zig.CrossTarget{};

    const showdown =
        b.option(bool, "showdown", "Enable Pokémon Showdown compatibility mode") orelse true;
    const module = pkmn.module(b, .{ .showdown = showdown });

    const bin = b.pathJoin(&.{ "node_modules", ".bin" });
    const install = b.findProgram(&.{"install-pkmn-engine"}, &.{bin}) catch unreachable;
    const options = b.fmt("--options=-Dlog{s}", .{if (showdown) " -Dshowdown" else ""});
    const engine = b.addSystemCommand(&[_][]const u8{ install, options, "--silent" });
    b.getInstallStep().dependOn(&engine.step);

    const node_modules = b.pathJoin(&.{ "node_modules", "@pkmn", "@engine", "build" });
    const node = if (b.findProgram(&.{"node"}, &.{})) |path| path else |_| {
        try std.io.getStdErr().writeAll("Cannot find node\n");
        std.process.exit(1);
    };
    const node_headers = headers: {
        var headers = resolve(b, &.{ node, "..", "..", "include", "node" });
        var node_h = b.pathJoin(&.{ headers, "node.h" });
        if (try exists(headers)) break :headers headers;
        headers = resolve(b, &.{ node_modules, "include" });
        node_h = b.pathJoin(&.{ headers, "node.h" });
        if (try exists(headers)) break :headers headers;
        try std.io.getStdErr().writeAll("Cannot find node headers\n");
        std.process.exit(1);
    };
    const node_import_lib = if (detect(target).os.tag == .windows) lib: {
        var lib = resolve(b, &.{ node, "..", "node.lib" });
        if (try exists(lib)) break :lib lib;
        lib = resolve(b, &.{ node_modules, "lib", "node.lib" });
        if (try exists(lib)) break :lib lib;
        try std.io.getStdErr().writeAll("Cannot find node import lib\n");
        std.process.exit(1);
    } else null;

    {
        const path = if (has_path) .{ .path = "src/lib/node.zig" } else b.path("src/lib/node.zig");
        const optimize = if (release) std.builtin.Mode.ReleaseFast else std.builtin.Mode.Debug;
        const addon = if (@hasField(std.Build.SharedLibraryOptions, "strip")) b.addSharedLibrary(.{
            .name = "addon",
            .root_source_file = path,
            .optimize = optimize,
            .target = target,
            .strip = release,
        }) else addon: {
            const a = b.addSharedLibrary(.{
                .name = "addon",
                .root_source_file = path,
                .optimize = optimize,
                .target = target,
            });
            a.strip = true;
            break :addon a;
        };
        if (root_module) {
            addon.root_module.addImport("pkmn", module);
        } else {
            addon.addModule("pkmn", module);
        }
        addon.addSystemIncludePath(.{ .cwd_relative = node_headers });
        addon.linkLibC();
        if (node_import_lib) |il| {
            addon.addObjectFile(if (has_path) .{ .path = il } else b.path(il));
        }
        addon.linker_allow_shlib_undefined = true;
        if (release) {
            if (b.findProgram(&.{"strip"}, &.{})) |strip| {
                if (builtin.os.tag != .macos) {
                    const sh = b.addSystemCommand(&.{ strip, "-s" });
                    sh.addArtifactArg(addon);
                    b.getInstallStep().dependOn(&sh.step);
                }
            } else |_| {}
        }
        b.getInstallStep().dependOn(
            &b.addInstallFileWithDir(addon.getEmittedBin(), .lib, "addon.node").step,
        );
    }
    {
        const entry = @hasDecl(CompileStep, "Entry");
        const freestanding = if (@hasDecl(std.Build, "resolveTargetQuery"))
            b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding })
        else
            std.zig.CrossTarget{ .cpu_arch = .wasm32, .os_tag = .freestanding };
        const optimize = if (release) std.builtin.Mode.ReleaseSmall else std.builtin.Mode.Debug;
        const path = if (has_path) .{ .path = "src/lib/wasm.zig" } else b.path("src/lib/wasm.zig");
        const wasm = if (entry) wasm: {
            const exe = b.addExecutable(if (@hasField(std.Build.ExecutableOptions, "strip")) .{
                .name = "addon",
                .root_source_file = path,
                .optimize = optimize,
                .target = freestanding,
                .strip = release,
            } else .{
                .name = "addon",
                .root_source_file = path,
                .optimize = optimize,
                .target = freestanding,
            });
            (if (root_module) exe.root_module else exe).export_symbol_names = &[_][]const u8{};
            exe.entry = .disabled;
            break :wasm exe;
        } else wasm: {
            const lib = b.addSharedLibrary(.{
                .name = "addon",
                .root_source_file = path,
                .optimize = optimize,
                .target = freestanding,
            });
            lib.rdynamic = true;
            break :wasm lib;
        };
        if (root_module) {
            wasm.root_module.addImport("pkmn", module);
        } else {
            wasm.addModule("pkmn", module);
        }

        wasm.stack_size = std.wasm.page_size;
        if (@hasDecl(@TypeOf(wasm.*), "strip")) wasm.strip = release;

        const installed = if (release) installed: {
            if (b.findProgram(&.{"wasm-opt"}, &.{bin})) |opt| {
                const sh = b.addSystemCommand(&.{ opt, "-O4" });
                sh.addArtifactArg(wasm);
                sh.addArg("-o");
                const out = "build/lib/addon.wasm";
                if (@hasDecl(@TypeOf(sh.*), "addFileSourceArg")) {
                    sh.addFileSourceArg(if (has_path) .{ .path = out } else b.path(out));
                } else {
                    sh.addFileArg(if (has_path) .{ .path = out } else b.path(out));
                }
                b.getInstallStep().dependOn(&sh.step);
                break :installed true;
            } else |_| break :installed false;
        } else false;
        if (!entry) {
            b.installArtifact(wasm);
        } else if (!installed) {
            b.getInstallStep().dependOn(&b.addInstallArtifact(wasm, .{
                .dest_dir = .{ .override = std.Build.InstallDir{ .lib = {} } },
            }).step);
        }
    }

    const test_filter =
        b.option([]const u8, "test-filter", "Skip tests that do not match filter");

    const path = if (has_path) .{ .path = "src/lib/test.zig" } else b.path("src/lib/test.zig");
    const optimize = if (release) std.builtin.Mode.ReleaseSafe else std.builtin.Mode.Debug;
    const tests = (if (@hasField(std.Build.TestOptions, "single_threaded")) b.addTest(.{
        .root_source_file = path,
        .optimize = optimize,
        .target = target,
        .filter = test_filter,
        .single_threaded = true,
    }) else tests: {
        const t = b.addTest(.{
            .root_source_file = path,
            .optimize = optimize,
            .target = target,
            .filter = test_filter,
        });
        t.single_threaded = true;
        break :tests t;
    });

    const lint = b.addSystemCommand(&.{"ziglint"});

    b.step("lint", "Lint source files").dependOn(&lint.step);
    b.step("test", "Run all tests").dependOn(&b.addRunArtifact(tests).step);
}

fn resolve(b: *std.Build, paths: []const []const u8) []u8 {
    return std.fs.path.resolve(b.allocator, paths) catch @panic("OOM");
}

fn exists(path: []const u8) !bool {
    return if (std.fs.accessAbsolute(path, .{})) |_| true else |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };
}

fn detect(target: anytype) std.Target {
    if (@hasField(@TypeOf(target), "result")) return target.result;
    return (std.zig.system.NativeTargetInfo.detect(target) catch unreachable).target;
}
