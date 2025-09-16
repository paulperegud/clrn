//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const clap = @import("clap");

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("clrn_lib");
const tree = @import("tree.zig");

const debug = std.debug.print;

var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

var stderr_buffer: [1024]u8 = undefined;
var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
const stderr = &stderr_writer.interface;

const usage =
    \\-h, --help           Print this message and exit.
    \\<DIRECTORY>          Directory name or `-` for stdin
;

const Options = struct {
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
        instance.*.items.deinit(allocator);
    }

    pub fn toTree(this: *Paths, allocator: std.mem.Allocator) !*DirTreeNode {
        const path_comps = std.fs.path.ComponentIterator(.posix, u8);
        const root: *DirTreeNode = try allocator.create(DirTreeNode);
        root.* = DirTreeNode.empty;
        root.name = "";
        var cur: *tree.Node = &root.node;
        if (this.items.items.len == 0) return root;
        for (this.items.items) |path| {
            cur = &root.node;
            var iter = try path_comps.init(path);
            while (iter.next()) |comp| {
                cur = for (cur.children.items) |child| {
                    const childDirNode = DirTreeNode.fromNode(child);
                    if (std.mem.eql(u8, comp.name, childDirNode.name)) {
                        // known path, use existing child
                        break child;
                    }
                } else else_block: {
                    // allocate new child
                    const newChild: *DirTreeNode = try allocator.create(DirTreeNode);
                    newChild.* = DirTreeNode.empty;
                    newChild.name = comp.name;
                    try tree.addChild(allocator, cur, null, &newChild.node);
                    break :else_block &newChild.node;
                };
            }
        }
        return root;
    }
};

const DirTreeNode = struct {
    node: tree.Node = .{},
    name: []const u8,

    pub const empty: DirTreeNode = .{ .node = .{}, .name = undefined };

    pub fn fromNode(node: *tree.Node) *DirTreeNode {
        return @fieldParentPtr("node", node);
    }

    pub fn printFlat(this: *DirTreeNode, io: *std.io.Writer) !void {
        var first = true;
        try io.print("{s}{{", .{this.name});
        for (this.node.children.items) |child| {
            if (!first) try io.print(", ", .{}) else first = false;
            const dirNode = DirTreeNode.fromNode(child);
            try dirNode.printFlat(io);
        }
        try io.print("}}", .{});
    }

    pub fn printTree(this: *DirTreeNode, io: *std.io.Writer, allocator: std.mem.Allocator) !void {
        var neighbours = std.ArrayList(bool).empty;
        // try neighbours.append(allocator, false);
        defer neighbours.deinit(allocator);
        try printTreeDeep(this, io, allocator, &neighbours);
    }

    fn printTreeDeep(this: *DirTreeNode, io: *std.io.Writer, allocator: std.mem.Allocator, prefix: *std.ArrayList(bool)) !void {
        const children = this.node.children;
        if (prefix.items.len > 1) {
            for (0..prefix.items.len - 1) |d| {
                if (prefix.items[d]) try io.print("│  ", .{}) else try io.print("   ", .{});
            }
        }
        if (prefix.items.len > 0) {
            if (prefix.items[prefix.items.len - 1]) try io.print("├──", .{}) else try io.print("└──", .{});
        }
        try io.print("{s}\n", .{this.name});
        if (children.items.len > 1) {
            try prefix.append(allocator, true);
            for (children.items[0 .. children.items.len - 1]) |childNode| {
                const child = DirTreeNode.fromNode(childNode);
                try printTreeDeep(child, io, allocator, prefix);
            }
            _ = prefix.pop();
        }
        if (children.items.len > 0) {
            try prefix.append(allocator, false);
            const childNode = children.items[children.items.len - 1];
            const child = DirTreeNode.fromNode(childNode);
            try printTreeDeep(child, io, allocator, prefix);
            _ = prefix.pop();
        }
    }

    // frees all the memory of this node and its children
    pub fn deinit(this: *DirTreeNode, allocator: std.mem.Allocator) void {
        for (this.*.node.children.items) |childNode| {
            const child = fromNode(childNode);
            child.deinit(allocator);
        }
        this.node.children.deinit(allocator);
        allocator.destroy(this);
    }
};

test "load paths print tree" {
    const allocator = std.testing.allocator;
    var file_buffer: [1024]u8 = undefined;
    const file = try std.fs.cwd().openFile("tests/tree.paths", .{});
    defer file.close();
    var reader = file.reader(&file_buffer);
    var files = try collectPathsFromFile(&reader, allocator);
    const filesAsTree: *DirTreeNode = try files.toTree(allocator);
    defer filesAsTree.deinit(allocator);
    try filesAsTree.printFlat(stderr);
    try stderr.print("\n", .{});
    try stderr.flush();
    try stderr.print("\n", .{});
    try filesAsTree.printTree(stderr, allocator);
    try stderr.print("\n", .{});
    try stderr.flush();
    defer Paths.free(allocator, &files);
}

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
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer params.deinit();

    var opts: Options = .{};
    if (params.args.help != 0) {
        try stdout.print("Usage:  clrn ", .{});
        try clap.usage(stdout, clap.Help, &parsed_help);
        try stdout.print("\n\n", .{});
        try clap.help(stdout, clap.Help, &parsed_help, .{ .spacing_between_parameters = 0 });
        try stdout.flush();
        std.posix.exit(1);
    }
    opts.directory = params.positionals[0] orelse ".";

    var files: Paths = try collectPaths(allocator, opts.directory);
    defer {
        for (files.items.items) |line| {
            allocator.free(line);
        }
        files.items.deinit(allocator);
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
        // TODO: size of this buffer should be determined by the size of the file
        const file = try std.fs.openFileAbsolute(cmd_file_name, .{});
        var file_buffer: [1024]u8 = undefined;
        var reader = file.reader(&file_buffer);
        defer file.close();
        // this is the way to return a value from a block of code...
        break :load_commands try collectPathsFromFile(&reader, allocator);
    };
    defer Paths.free(allocator, &commands);
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
    const commandsTree = try commands.toTree(allocator);
    defer commandsTree.deinit(allocator);
    try commandsTree.printTree(stderr, allocator);
    try stderr.flush();

    // ask if continue
    while (true) {
        const mbanswer = try getInteractiveChoice("Commit this change?", &.{ .{ .short = 'y', .long = "yes", .default = true }, .{ .short = 'n', .long = "no" } });
        if (mbanswer) |answer| {
            if (answer.short != 'y') {
                debug("exiting...", .{});
                std.posix.exit(0);
            }
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
    var source_dir = try cwd.openDir(source_dir_path, .{});
    defer source_dir.close();
    var target_dir = try cwd.openDir(target_dir_path, .{});
    defer target_dir.close();
    std.fs.rename(source_dir, std.fs.path.basename(source), target_dir, std.fs.path.basename(target)) catch |err| switch (err) {
        error.PathAlreadyExists => {
            debug("Path {s} already exists!\n", .{target});
            std.posix.exit(1);
        },
        error.RenameAcrossMountPoints => {
            try copyFile(cwd, source, target);
        },
        else => return err,
    };
}

pub fn copyFile(cwd: std.fs.Dir, source: []const u8, dest: []const u8) !void {
    const source_dir_path = std.fs.path.dirname(source) orelse ".";
    const dest_dir_path = std.fs.path.dirname(dest) orelse ".";
    var source_dir = try cwd.openDir(source_dir_path, .{});
    defer source_dir.close();
    var dest_dir = try cwd.openDir(dest_dir_path, .{});
    defer dest_dir.close();
    try source_dir.copyFile(std.fs.path.basename(source), dest_dir, std.fs.path.basename(dest), .{});
}

test "test 1." {
    const allocator = std.testing.allocator;
    const cwd = try std.fs.cwd().openDir("tests", .{});
    var files = try collectPathsFromDirectory(allocator, try cwd.openDir("1.source/", .{ .iterate = true }));
    defer Paths.free(allocator, &files);
    var file_buffer: [1024]u8 = undefined;
    var commands_reader = (try cwd.openFile("1.cmd", .{})).reader(&file_buffer);
    var commands = try collectPathsFromFile(&commands_reader, allocator);
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

pub fn getInteractiveChoice(prompt: []const u8, options: []const InteractiveChoice) !?InteractiveChoice {
    debug("{s} [", .{prompt});
    var first = true;
    for (options) |option| {
        if (!first) {
            debug("/", .{});
        }
        if (!option.default)
            debug("{s}", .{[1]u8{option.short}})
        else
            debug("[{s}]", .{[1]u8{option.short - 32}});
        first = false;
    }
    debug("] ", .{});
    var confirmation_buffer: [5]u8 = undefined;
    var reader = std.fs.File.stdin().reader(&confirmation_buffer);
    const answer = try reader.interface.takeDelimiterExclusive('\n');
    const choice = for (options) |option| {
        if (std.ascii.eqlIgnoreCase(&[_]u8{option.short}, answer)) break option;
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
        // figure out the strategy for the buffer size here...
        var stdin_buffer: [1024]u8 = undefined;
        var reader = std.fs.File.stdin().reader(&stdin_buffer);
        return try collectPathsFromFile(&reader, allocator);
    }
}

pub fn collectPathsFromFile(reader: *std.fs.File.Reader, allocator: std.mem.Allocator) !Paths {
    var result = std.ArrayList([]const u8).empty;
    while (reader.interface.takeDelimiterExclusive('\n')) |line| {
        const ownedline: []u8 = try allocator.alloc(u8, line.len);
        std.mem.copyForwards(u8, ownedline, line);
        try result.append(allocator, ownedline);
    } else |err| switch (err) {
        error.EndOfStream => return .{ .items = result },
        error.StreamTooLong, error.ReadFailed => return err,
    }
}

pub fn collectPathsFromDirectory(allocator: std.mem.Allocator, dir: std.fs.Dir) !Paths {
    var result = std.ArrayList([]const u8).empty;
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind == .directory) continue;
        if (entry.path.len == 0) continue;
        const copy: []u8 = try allocator.alloc(u8, entry.path.len);
        std.mem.copyForwards(u8, copy, entry.path);
        try result.append(allocator, copy);
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
    var list = std.ArrayList(i32).empty;
    defer list.deinit(std.testing.allocator); // Try commenting this out and see if zig detects the memory leak!
    try list.append(std.testing.allocator, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

// test "fuzz example" {
//     const Context = struct {
//         fn testOne(context: @This(), input: []const u8) anyerror!void {
//             _ = context;
//             // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
//             try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
//         }
//     };
//     try std.testing.fuzz(Context{}, Context.testOne, .{});
// }
