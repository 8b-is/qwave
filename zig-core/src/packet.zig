const std = @import("std");

/// Opaque filter state, allocated by init and freed by deinit.
const FilterState = struct {
    allocator: std.mem.Allocator,
    packets_seen: u64,
    packets_dropped: u64,
};

export fn qpacket_filter_init() callconv(.c) ?*anyopaque {
    const state = std.heap.c_allocator.create(FilterState) catch return null;
    state.* = .{
        .allocator = std.heap.c_allocator,
        .packets_seen = 0,
        .packets_dropped = 0,
    };
    return state;
}

/// Filter a single packet. Returns 0 (allow) or 1 (drop).
/// Currently a pass-through — all packets allowed. Future versions will
/// inspect the packet header and apply firewall rules.
export fn qpacket_filter(state: ?*anyopaque, packet: [*]const u8, len: usize) callconv(.c) c_int {
    const s: *FilterState = @ptrCast(@alignCast(state orelse return 0));
    s.packets_seen += 1;
    _ = packet;
    _ = len;
    // TODO: packet inspection — parse IP header, apply rules
    return 0; // allow
}

export fn qpacket_filter_stats(state: ?*anyopaque, seen: *u64, dropped: *u64) callconv(.c) void {
    const s: *FilterState = @ptrCast(@alignCast(state orelse return));
    seen.* = s.packets_seen;
    dropped.* = s.packets_dropped;
}

export fn qpacket_filter_deinit(state: ?*anyopaque) callconv(.c) void {
    const s: *FilterState = @ptrCast(@alignCast(state orelse return));
    std.heap.c_allocator.destroy(s);
}

test "filter state lifecycle" {
    const state = qpacket_filter_init();
    try std.testing.expect(state != null);

    var seen: u64 = 0;
    var dropped: u64 = 0;
    qpacket_filter_stats(state, &seen, &dropped);
    try std.testing.expectEqual(@as(u64, 0), seen);
    try std.testing.expectEqual(@as(u64, 0), dropped);

    const packet = [_]u8{0x45} ** 40;
    const verdict = qpacket_filter(state, &packet, packet.len);
    try std.testing.expectEqual(@as(c_int, 0), verdict);

    qpacket_filter_stats(state, &seen, &dropped);
    try std.testing.expectEqual(@as(u64, 1), seen);
    try std.testing.expectEqual(@as(u64, 0), dropped);

    qpacket_filter_deinit(state);
}