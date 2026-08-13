const std = @import("std");
const Io = std.Io;

/// A single WKContentRuleList rule.
const Rule = struct {
    trigger: struct {
        @"url-filter": []const u8,
    },
    action: struct {
        @"type": []const u8,
        selector: ?[]const u8 = null,
    },
};

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    const json_path = if (args.len > 1) args[1] else "../Packages/QwaveKit/Sources/Shields/Resources/easylist-compiled.json";

    const file = try Io.Dir.openFile(Io.Dir.cwd(), io, json_path, .{ .mode = .read_only });
    defer file.close(io);

    const stat = try Io.File.stat(file, io);
    const content = try arena.alloc(u8, stat.size);
    const bytes_read = try Io.File.readPositionalAll(file, io, content, 0);
    _ = bytes_read;

    const rules = try std.json.parseFromSlice([]Rule, arena, content, .{ .ignore_unknown_fields = true });

    const total = rules.value.len;
    var blocks: usize = 0;
    var css_hide: usize = 0;
    var ignore_prev: usize = 0;
    var unknown: usize = 0;

    for (rules.value) |rule| {
        const action_type = std.mem.trim(u8, rule.action.@"type", " ");
        if (std.mem.eql(u8, action_type, "block")) {
            blocks += 1;
        } else if (std.mem.eql(u8, action_type, "css-display-none")) {
            css_hide += 1;
        } else if (std.mem.eql(u8, action_type, "ignore-previous-rules")) {
            ignore_prev += 1;
        } else {
            unknown += 1;
        }
    }

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const w = &stdout_writer.interface;

    try w.print("Validating: {s}\n", .{json_path});
    try w.print("  Total rules: {d}\n", .{total});
    try w.print("  block:              {d:>6}  ({d:>5.1}%)\n", .{ blocks, @as(f64, @floatFromInt(blocks)) / @as(f64, @floatFromInt(total)) * 100.0 });
    try w.print("  css-display-none:   {d:>6}  ({d:>5.1}%)\n", .{ css_hide, @as(f64, @floatFromInt(css_hide)) / @as(f64, @floatFromInt(total)) * 100.0 });
    try w.print("  ignore-previous-rules: {d:>3}  ({d:>5.1}%)\n", .{ ignore_prev, @as(f64, @floatFromInt(ignore_prev)) / @as(f64, @floatFromInt(total)) * 100.0 });
    try w.print("  unknown:            {d:>6}  ({d:>5.1}%)\n", .{ unknown, @as(f64, @floatFromInt(unknown)) / @as(f64, @floatFromInt(total)) * 100.0 });

    if (unknown > 0) {
        try w.print("  WARNING: {d} rules with unknown action type\n", .{unknown});
    }

    const expected: usize = 59657;
    if (total != expected) {
        try w.print("  WARNING: expected {d} rules, got {d}\n", .{ expected, total });
    }

    try w.print("Result: {s}\n", .{if (total > 0 and unknown == 0) "VALID" else if (total == 0) "EMPTY" else "ISSUES FOUND"});
    try w.flush();

    if (total == 0 or unknown > 0) std.process.exit(1);
}

test "basic validation" {
    const sample = [_]Rule{
        .{
            .trigger = .{ .@"url-filter" = ".*" },
            .action = .{ .@"type" = "block" },
        },
        .{
            .trigger = .{ .@"url-filter" = "^[^:]+://+example\\.com/" },
            .action = .{ .@"type" = "css-display-none", .selector = "#ad" },
        },
        .{
            .trigger = .{ .@"url-filter" = ".*" },
            .action = .{ .@"type" = "ignore-previous-rules" },
        },
    };
    try std.testing.expectEqual(@as(usize, 3), sample.len);
    try std.testing.expectEqualStrings("block", sample[0].action.@"type");
    try std.testing.expectEqualStrings("css-display-none", sample[1].action.@"type");
    try std.testing.expectEqualStrings("ignore-previous-rules", sample[2].action.@"type");
}