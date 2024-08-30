const std = @import("std");
const builtin = @import("builtin");

const pkmn = @import("node_modules/@pkmn/engine/build.zig");

pub fn build(b: *std.Build) !void {
    const release = if (std.os.getenv("DEBUG_PKMN_ENGINE")) |_| false else true;
    const target = std.zig.CrossTarget{};

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
    var node_headers = headers: {
        var headers = resolve(b, &.{ node, "..", "..", "include", "node" });
        var node_h = b.pathJoin(&.{ headers, "node.h" });
        if (try exists(headers)) break :headers headers;
        headers = resolve(b, &.{ node_modules, "include" });
        node_h = b.pathJoin(&.{ headers, "node.h" });
        if (try exists(headers)) break :headers headers;
        try std.io.getStdErr().writeAll("Cannot find node headers\n");
        std.process.exit(1);
    };
    const windows = (try std.zig.system.NativeTargetInfo.detect(target)).target.os.tag == .windows;
    const node_import_lib = if (windows) lib: {
        var lib = resolve(b, &.{ node, "..", "node.lib" });
        if (try exists(lib)) break :lib lib;
        lib = resolve(b, &.{ node_modules, "lib", "node.lib" });
        if (try exists(lib)) break :lib lib;
        try std.io.getStdErr().writeAll("Cannot find node import lib\n");
        std.process.exit(1);
    } else null;

    const addon = b.addSharedLibrary(.{
        .name = "addon",
        .root_source_file = .{ .path = "src/lib/node.zig" },
        .optimize = if (release) .ReleaseFast else .Debug,
        .target = target,
    });
    addon.addModule("pkmn", module);
    addon.addSystemIncludePath(.{ .path = node_headers });
    addon.linkLibC();
    if (node_import_lib) |il| addon.addObjectFile(.{ .path = il });
    addon.linker_allow_shlib_undefined = true;
    if (release) {
        addon.strip = true;
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

    const wasm = b.addSharedLibrary(.{
        .name = "addon",
        .root_source_file = .{ .path = "src/lib/wasm.zig" },
        .optimize = if (release) .ReleaseSmall else .Debug,
        .target = .{ .cpu_arch = .wasm32, .os_tag = .freestanding },
    });
    wasm.addModule("pkmn", module);
    wasm.stack_size = std.wasm.page_size;
    wasm.rdynamic = true;
    if (release) {
        wasm.strip = true;
        if (b.findProgram(&.{"wasm-opt"}, &.{bin})) |opt| {
            const sh = b.addSystemCommand(&.{ opt, "-O4" });
            sh.addArtifactArg(wasm);
            sh.addArg("-o");
            sh.addFileSourceArg(.{ .path = "build/lib/addon.wasm" });
            b.getInstallStep().dependOn(&sh.step);
        } else |_| {}
    }
    b.installArtifact(wasm);

    const test_file = b.option([]const u8, "test-file", "Input file for test") orelse
        "src/lib/test.zig";
    const test_filter =
        b.option([]const u8, "test-filter", "Skip tests that do not match filter");

    const tests = b.addTest(.{
        .name = std.fs.path.basename(std.fs.path.dirname(test_file).?),
        .root_source_file = .{ .path = test_file },
        .optimize = if (release) .ReleaseSafe else .Debug,
        .target = target,
        .filter = test_filter,
    });
    tests.single_threaded = true;

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
