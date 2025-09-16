const std = @import("std");
const debug = std.debug.print;
const Children = std.ArrayListUnmanaged(*Node);
const Allocator = std.mem.Allocator;

const DoublyLinkedTree = @This();

pub const Node = struct {
    const Self = @This();
    parent: ?*Node = null,
    children: Children = Children.empty,

    pub const empty: Self = .{
        .children = Children.empty,
        .parent = null,
    };
};

pub fn addChild(allocator: Allocator, node: *Node, after: ?*Node, new_node: *Node) !void {
    new_node.parent = node;
    if (after) |after_node| {
        const index = for (node.*.children.items, 0..) |child, i| {
            if (child == after_node) break i;
        } else node.*.children.items.len;
        try node.*.children.insert(allocator, index, new_node);
    } else {
        try node.*.children.append(allocator, new_node);
    }
}
