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
    \\--nvim               Run nvim and pipe text into it
    \\<DIRECTORY>          Directory name or `-` for stdin
;

const Options = struct {
    debugShowSource: bool = false,
    debugRunNVim: bool = false,
    directory: []const u8 = undefined,
};

const Paths = struct {
    items: std.ArrayList([]const u8),
    pub fn eql(this: *Paths, other: Paths) bool {
        const this_items = this.*.items.items;
        const other_items = other.items.items;
        if (this_items.len != other_items.len) return false;
        for (this_items, 0..) |this_item, index| {
            if (!std.mem.eql(u8, this_item, other_items[index])) return false;
        }
        return true;
    }

    pub fn free(allocator: std.mem.Allocator, instance: *Paths) void {
        for (instance.*.items.items) |line| {
            allocator.free(line);
        }
        instance.*.items.deinit();
    }
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
        std.posix.exit(1);
    };
    defer params.deinit();

    var opts: Options = .{};
    if (params.args.help != 0) {
        try bw.writer().print("Usage:  clrn ", .{});
        try clap.usage(bw.writer(), clap.Help, &parsed_help);
        try bw.writer().print("\n\n", .{});
        try clap.help(bw.writer(), clap.Help, &parsed_help, .{ .spacing_between_parameters = 0 });
        try bw.flush();
        std.posix.exit(1);
    }
    if (params.args.debug != 0) {
        opts.debugShowSource = true;
    }
    if (params.args.nvim != 0) {
        opts.debugRunNVim = true;
    }
    opts.directory = params.positionals[0] orelse ".";

    var files: Paths = try collectPaths(allocator, opts.directory);
    defer {
        for (files.items.items) |line| {
            allocator.free(line);
        }
        files.items.deinit();
    }

    if (opts.debugShowSource) {
        for (files.items.items) |line| {
            debug("file: {s}\n", .{line});
        }
        std.posix.exit(1);
    }

    const cmd_file_name: []const u8 = try writeFilesToTmpfileAlloc(allocator, files);
    defer allocator.free(cmd_file_name);
    defer {
        _ = std.fs.deleteFileAbsolute(cmd_file_name) catch |err| {
            debug("tmp file deletion failed: {any}\n", .{err});
        };
    }
    var nvim = std.process.Child.init(&.{ "nvim", cmd_file_name }, allocator);
    // wait for nvim
    _ = try nvim.spawn();
    _ = try nvim.wait();
    // read the file
    var commands: Paths = load_commands: {
        const file = try std.fs.openFileAbsolute(cmd_file_name, .{});
        const reader = file.reader();
        defer file.close();
        // this is the way to return a value from a block of code...
        break :load_commands try collectPathsFromFile(reader, allocator);
    };
    defer {
        for (commands.items.items) |line| {
            allocator.free(line);
        }
        commands.items.deinit();
    }
    // number of lines changed means ambiguity in what should be renamed to what
    if (commands.items.items.len != files.items.items.len) {
        debug("Number of lines changed, please retry.\n", .{});
        std.posix.exit(1);
    }
    // cleanup identical lines in source and target
    const total_files = files.items.items.len;
    for (1..files.items.items.len + 1) |i| {
        const index = total_files - i;
        if (std.mem.eql(u8, files.items.items[index], commands.items.items[index])) {
            allocator.free(files.items.orderedRemove(index));
            allocator.free(commands.items.orderedRemove(index));
        }
    }
    // check if there is actual work to be done
    if (files.items.items.len == 0) {
        debug("File names are unchanged.\n", .{});
        std.posix.exit(1);
    }
    // print it
    debug("imagine that this is your commands, printed out...\n", .{});
    // ask if continue
    while (true) {
        const mbanswer = try getInteractiveChoice(allocator, "Commit this change?", &.{ .{ .short = 'y', .long = "yes" }, .{ .short = 'n', .long = "no" } });
        if (mbanswer) |answer| {
            debug("committing... {s}\n", .{answer.long});
            break;
        } else {
            debug("Please answer one of the following...\n", .{});
        }
    }
    // modify paths
    const cwd = try std.fs.cwd().openDir(opts.directory, .{});
    _ = try transform_tree(cwd, files, commands);
}

pub fn transform_tree(cwd: std.fs.Dir, from: Paths, to: Paths) !void {
    const path_comps = std.fs.path.ComponentIterator(.posix, u8);
    for (from.items.items, 0..) |source, index| {
        const target = to.items.items[index];
        debug("{s} => {s}\n", .{ source, target });
        var iter = try path_comps.init(target);
        while (iter.next()) |comp| {
            if (iter.peekNext()) |_| {
                if (cwd.makeDir(comp.path)) {} else |err| switch (err) {
                    error.PathAlreadyExists => continue,
                    else => return err,
                }
            } else {
                _ = try moveFile(cwd, source, target);
            }
        }
    }
}

pub fn moveFile(cwd: std.fs.Dir, source: []const u8, target: []const u8) !void {
    const source_dir_path = std.fs.path.dirname(source) orelse ".";
    const target_dir_path = std.fs.path.dirname(target) orelse ".";
    const source_dir = try cwd.openDir(source_dir_path, .{});
    const target_dir = try cwd.openDir(target_dir_path, .{});
    std.fs.rename(source_dir, std.fs.path.basename(source), target_dir, std.fs.path.basename(target)) catch |err| switch (err) {
        error.PathAlreadyExists => {
            debug("Path {s} already exists!\n", .{target});
            std.posix.exit(1);
        },
        else => return err,
    };
}

test "test 1." {
    const allocator = std.testing.allocator;
    const cwd = try std.fs.cwd().openDir("tests", .{});
    var files = try collectPathsFromDirectory(allocator, try cwd.openDir("1.source/", .{ .iterate = true }));
    defer Paths.free(allocator, &files);
    const commands_reader = (try cwd.openFile("1.cmd", .{})).reader();
    var commands = try collectPathsFromFile(commands_reader, allocator);
    defer Paths.free(allocator, &commands);

    try transform_tree(try cwd.openDir("1.source/", .{}), files, commands);
}

test "iter path" {
    const path_comps = std.fs.path.ComponentIterator(.posix, u8);
    var iter = try path_comps.init("file.txt");
    while (iter.next()) |comp| {
        debug("comp is {s}\n", .{comp.name});
    }
}

const InteractiveChoice = struct {
    short: u8,
    long: []const u8,
    default: bool = false,
};

pub fn getInteractiveChoice(allocator: std.mem.Allocator, prompt: []const u8, options: []const InteractiveChoice) !?InteractiveChoice {
    debug("{s} [", .{prompt});
    var first = true;
    for (options) |option| {
        if (!first) {
            debug("/", .{});
        }
        debug("{s}", .{[1]u8{option.short}});
        first = false;
    }
    debug("] ", .{});
    const reader = std.io.getStdIn().reader();
    var buff: [5]u8 = undefined;
    const answerAnyCase = try reader.readUntilDelimiter(&buff, '\n');
    const answer = try std.ascii.allocLowerString(allocator, answerAnyCase);
    defer allocator.free(answer);
    const choice = for (options) |option| {
        if (std.mem.eql(u8, &[_]u8{option.short}, answer)) break option;
    } else for (options) |option| {
        if (option.default) break option;
    } else null;
    return choice;
}

pub fn writeFilesToTmpfileAlloc(allocator: std.mem.Allocator, files: Paths) ![]const u8 {
    const tmp = std.posix.getenv("TMP");
    const cmd_file_name: []const u8 = try std.fs.path.join(allocator, &.{ tmp.?, "clrn.cmd" });
    const cmd_file = try std.fs.createFileAbsolute(cmd_file_name, .{});
    for (files.items.items) |line| {
        _ = try cmd_file.write(line);
        _ = try cmd_file.write("\n");
    }
    cmd_file.close();
    return cmd_file_name;
}

pub fn collectPaths(allocator: std.mem.Allocator, source: []const u8) !Paths {
    if (!std.mem.eql(u8, source, "-")) {
        const cwd = std.fs.cwd();
        const dir: std.fs.Dir = try cwd.openDir(source, .{ .iterate = true });
        return try collectPathsFromDirectory(allocator, dir);
    } else {
        const reader = std.io.getStdIn().reader();
        return try collectPathsFromFile(reader, allocator);
    }
}

pub fn collectPathsFromFile(reader: std.fs.File.Reader, allocator: std.mem.Allocator) !Paths {
    var result = std.ArrayList([]const u8).init(allocator);
    var buf: [1024]u8 = undefined;
    while (true) {
        const mbline = try reader.readUntilDelimiterOrEof(&buf, '\n');
        if (mbline) |line| {
            const ownedline: []u8 = try allocator.alloc(u8, line.len);
            std.mem.copyForwards(u8, ownedline, line);
            try result.append(ownedline);
        } else return .{ .items = result };
    }
}

pub fn collectPathsFromDirectory(allocator: std.mem.Allocator, dir: std.fs.Dir) !Paths {
    var result = std.ArrayList([]const u8).init(allocator);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind == .directory) continue;
        if (entry.path.len == 0) continue;
        const copy: []u8 = try allocator.alloc(u8, entry.path.len);
        std.mem.copyForwards(u8, copy, entry.path);
        try result.append(copy);
    }
    return .{ .items = result };
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
