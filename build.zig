const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = get_options(b);

    const page = b.addModule("page", .{
        .root_source_file = b.path("src/storage/page/page.zig"),
        .target = target,
        .optimize = optimize,
    });
    page.addOptions("options", options);

    const heap = b.addModule("heap", .{
        .root_source_file = b.path("src/storage/heap/heap.zig"),
        .target = target,
        .optimize = optimize,
    });
    heap.addImport("page", page);
    heap.addOptions("options", options);

    const test_step = b.step("test", "Run page module tests");

    initialize_tests(b, test_step, &.{ page, heap });
}

fn initialize_tests(b: *std.Build, test_step: *std.Build.Step, modules: []const *std.Build.Module) void {
    for (modules) |module| {
        const module_tests = b.addTest(.{ .root_module = module });
        const run_tests = b.addRunArtifact(module_tests);

        test_step.dependOn(&run_tests.step);
    }
}

fn get_options(b: *std.Build) *std.Build.Step.Options {
    const input = b.option(
        []const u8,
        "page-size",
        "Database page size: 1KB, 2KB, 4KB, 8KB, 16KB, or 32KB (case-insensitive)",
    ) orelse "8KB";

    const page_size = parsePageSize(input) orelse
        std.debug.panic("unsupported page size '{s}'; use 1KB, 2KB, 4KB, 8KB, 16KB, or 32KB", .{input});

    const options = b.addOptions();
    options.addOption(usize, "page_size", @backingInt(page_size));
    return options;
}

fn parsePageSize(input: []const u8) ?PageSize {
    const choices = .{
        .{ "1KB", PageSize.kb1 },
        .{ "2KB", PageSize.kb2 },
        .{ "4KB", PageSize.kb4 },
        .{ "8KB", PageSize.kb8 },
        .{ "16KB", PageSize.kb16 },
        .{ "32KB", PageSize.kb32 },
    };
    inline for (choices) |choice| {
        if (std.ascii.eqlIgnoreCase(input, choice[0])) return choice[1];
    }
    return null;
}

const PageSize = enum(usize) {
    kb1 = 1024,
    kb2 = 2048,
    kb4 = 4096,
    kb8 = 8192,
    kb16 = 16384,
    kb32 = 32768,
};
