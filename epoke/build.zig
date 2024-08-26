const std = @import("std");
const builtin = @import("builtin");

const getenv = if (@hasDecl(std, "posix")) std.posix.getenv else std.os.getenv;

pub fn build(b: *std.Build) !void {
    const release = if (getenv("DEBUG_PKMN_ENGINE")) |_| false else true;
    const target = b.resolveTargetQuery(.{});

    const showdown =
        b.option(bool, "showdown", "Enable Pokémon Showdown compatibility mode") orelse true;
    const pkmn = b.dependency("pkmn", .{ .showdown = showdown });

    const BIN = b.pathJoin(&.{ "node_modules", ".bin" });
    const install = b.findProgram(&.{"install-pkmn-engine"}, &.{BIN}) catch unreachable;
    const options = b.fmt("--options=-Dlog{s}", .{if (showdown) " -Dshowdown" else ""});
    const engine = b.addSystemCommand(&[_][]const u8{ install, options, "--silent" });
    b.getInstallStep().dependOn(&engine.step);

    const NODE_MODULES = b.pathJoin(&.{ "node_modules", "@pkmn", "@engine", "build" });
    const node = if (b.findProgram(&.{"node"}, &.{})) |path| path else |_| {
        try std.io.getStdErr().writeAll("Cannot find node\n");
        std.process.exit(1);
    };
    const node_headers = headers: {
        var headers = resolve(b, &.{ node, "..", "..", "include", "node" });
        var node_h = b.pathJoin(&.{ headers, "node.h" });
        if (try exists(headers)) break :headers headers;
        headers = resolve(b, &.{ NODE_MODULES, "include" });
        node_h = b.pathJoin(&.{ headers, "node.h" });
        if (try exists(headers)) break :headers headers;
        try std.io.getStdErr().writeAll("Cannot find node headers\n");
        std.process.exit(1);
    };
    const node_import_lib = if (target.result.os.tag == .windows) lib: {
        var lib = resolve(b, &.{ node, "..", "node.lib" });
        if (try exists(lib)) break :lib lib;
        lib = resolve(b, &.{ NODE_MODULES, "lib", "node.lib" });
        if (try exists(lib)) break :lib lib;
        try std.io.getStdErr().writeAll("Cannot find node import lib\n");
        std.process.exit(1);
    } else null;

    const addon = b.addSharedLibrary(.{
        .name = "addon",
        .root_source_file = b.path("src/lib/node.zig"),
        .optimize = if (release) .ReleaseFast else .Debug,
        .target = target,
        .strip = release,
    });
    addon.root_module.addImport("pkmn", pkmn.module("pkmn"));
    addon.addSystemIncludePath(.{ .cwd_relative = node_headers });
    addon.linkLibC();
    if (node_import_lib) |il| addon.addObjectFile(b.path(il));
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

    const wasm = b.addExecutable(.{
        .name = "addon",
        .root_source_file = b.path("src/lib/wasm.zig"),
        .optimize = if (release) .ReleaseSmall else .Debug,
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .strip = release,
    });
    wasm.root_module.addImport("pkmn", pkmn.module("pkmn"));
    wasm.root_module.export_symbol_names = &[_][]const u8{};
    wasm.entry = .disabled;
    wasm.stack_size = std.wasm.page_size;

    const installed = if (release) installed: {
        if (b.findProgram(&.{"wasm-opt"}, &.{BIN})) |opt| {
            const sh = b.addSystemCommand(&.{ opt, "-O4" });
            sh.addArtifactArg(wasm);
            sh.addArg("-o");
            sh.addFileArg(b.path("build/lib/addon.wasm"));
            b.getInstallStep().dependOn(&sh.step);
            break :installed true;
        } else |_| break :installed false;
    } else false;
    if (!installed) {
        b.getInstallStep().dependOn(&b.addInstallArtifact(wasm, .{
            .dest_dir = .{ .override = std.Build.InstallDir{ .lib = {} } },
        }).step);
    }

    const test_file = b.option([]const u8, "test-file", "Input file for test") orelse
        "src/lib/test.zig";
    const test_filter =
        b.option([]const u8, "test-filter", "Skip tests that do not match filter");

    const tests = b.addTest(.{
        .name = std.fs.path.basename(std.fs.path.dirname(test_file).?),
        .root_source_file = b.path(test_file),
        .optimize = if (release) .ReleaseSafe else .Debug,
        .target = target,
        .filter = test_filter,
        .single_threaded = true,
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
