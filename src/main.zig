//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const clap = @import("clap");

const debug = std.debug.print;

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();
var bw = std.io.bufferedWriter(stdout);

const usage =
    \\-h, --help           Print this message and exit.
    \\--debug              Show list of files as collected from directory or stdin
    \\<DIRECTORY>          Directory name or `-` for stdin
;

const Options = struct {
    debugShowSource: bool = false,
    directory: []const u8 = undefined,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("leak");
    const allocator = gpa.allocator();

    const parsed_help = comptime clap.parseParamsComptime(usage);

    const parsers = comptime .{
        .DIRECTORY = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    const params = clap.parse(clap.Help, &parsed_help, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer params.deinit();

    var opts: Options = .{};
    if (params.args.help != 0) {
        try bw.writer().print("Usage:  clrn ", .{});
        try clap.usage(bw.writer(), clap.Help, &parsed_help);
        try bw.writer().print("\n\n", .{});
        try clap.help(bw.writer(), clap.Help, &parsed_help, .{ .spacing_between_parameters = 0 });
        try bw.flush();
    }
    if (params.args.debug != 0) {
        opts.debugShowSource = true;
    }
    opts.directory = params.positionals[0] orelse ".";

    if (opts.debugShowSource) {
        const files: std.ArrayList([]const u8) = try collect_files(allocator, opts.directory);
        defer files.deinit();
        for (files.items) |line| {
            debug("file: {s}\n", .{line});
            allocator.free(line);
        }
        return;
    }

    try bw.flush(); // Don't forget to flush!
}

pub fn collect_files(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList([]const u8) {
    var result = std.ArrayList([]const u8).init(allocator);
    const cwd = std.fs.cwd();
    const dir: std.fs.Dir = try cwd.openDir(source, .{ .iterate = true });
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.path.len == 0) continue;
        const copy: []u8 = try allocator.alloc(u8, entry.path.len);
        std.mem.copyForwards(u8, copy, entry.path);
        try result.append(copy);
    }
    return result;
}

test "read tree" {
    const allocator = std.testing.allocator;

    const command_path = "./1.cmd";
    const outcome_path = "./1.expected";

    const cwd = try std.fs.cwd().openDir("tests", .{ .iterate = true });

    const command_size = (try cwd.statFile(command_path)).size;
    const command_file = try cwd.openFile(command_path, .{});
    defer command_file.close();
    const command_file_buffer = try command_file.readToEndAlloc(allocator, command_size);
    defer allocator.free(command_file_buffer);
    var command_line_iter = std.mem.splitSequence(u8, command_file_buffer, "\n");

    var dir = try cwd.openDir(outcome_path, .{ .iterate = true });
    defer dir.close();
    var dir_walker = try dir.walk(allocator);
    defer dir_walker.deinit();

    while (true) {
        const mbfile = try dir_walker.next();
        if (mbfile) |file| {
            if (file.kind == .directory) continue;
            const mbline = command_line_iter.next();
            try std.testing.expectEqualStrings(file.path, mbline.?);
        } else {
            const expected_null: ?[]const u8 = command_line_iter.next();
            // if file was terminated with empty line, len is zero, otherwise null is returned
            try std.testing.expect(expected_null.?.len == 0 or expected_null == null);
            return;
        }
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // Try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "use other module" {
    try std.testing.expectEqual(@as(i32, 150), lib.add(100, 50));
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("clrn_lib");
