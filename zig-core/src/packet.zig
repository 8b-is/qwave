const std = @import("std");

/// IP protocol identifiers.
const Protocol = enum(u8) {
    tcp = 6,
    udp = 17,
    icmp = 1,
    icmpv6 = 58,
    _,
};

/// Filter verdict.
const Verdict = enum(c_int) {
    allow = 0,
    drop = 1,
};

/// Opaque filter state, allocated by init and freed by deinit.
const FilterState = struct {
    allocator: std.mem.Allocator,
    packets_seen: u64,
    packets_dropped: u64,
    packets_tcp: u64,
    packets_udp: u64,
    packets_icmp: u64,
    packets_other: u64,
    packets_ipv4: u64,
    packets_ipv6: u64,
    bytes_seen: u64,
};

/// Parse an IPv4 header and return the protocol, or null if invalid.
fn parseIPv4(packet: []const u8) ?Protocol {
    if (packet.len < 20) return null;
    const version_ihl = packet[0];
    const version = version_ihl >> 4;
    if (version != 4) return null;
    const ihl = (version_ihl & 0x0F) * 4;
    if (ihl < 20 or packet.len < ihl) return null;
    const total_len = std.mem.readInt(u16, packet[2..4], .big);
    if (total_len < ihl or total_len > packet.len) return null;
    return @enumFromInt(packet[9]);
}

/// Parse an IPv6 header and return the protocol, or null if invalid.
fn parseIPv6(packet: []const u8) ?Protocol {
    if (packet.len < 40) return null;
    const version = packet[0] >> 4;
    if (version != 6) return null;
    const payload_len = std.mem.readInt(u16, packet[4..6], .big);
    if (packet.len < 40 + payload_len) return null;
    return @enumFromInt(packet[6]);
}

export fn qpacket_filter_init() callconv(.c) ?*anyopaque {
    const state = std.heap.c_allocator.create(FilterState) catch return null;
    state.* = .{
        .allocator = std.heap.c_allocator,
        .packets_seen = 0,
        .packets_dropped = 0,
        .packets_tcp = 0,
        .packets_udp = 0,
        .packets_icmp = 0,
        .packets_other = 0,
        .packets_ipv4 = 0,
        .packets_ipv6 = 0,
        .bytes_seen = 0,
    };
    return state;
}

/// Filter a single raw IP packet. Returns 0 (allow) or 1 (drop).
///
/// Called from the WireGuard Go tun wrapper (`qwave_filter_tun.go`) on every
/// Read (host → peer) and Write (peer → host). `PacketTunnelProvider` owns
/// the handle, passes it in with `wgSetPacketFilter`, and can read these
/// counters over `handleAppMessage`.
///
/// Validation:
///  - Minimum packet length: 20 bytes (IPv4 min) / 40 bytes (IPv6 min).
///  - IP version field must be 4 or 6.
///  - IPv4 total length and IHL must be consistent.
///  - IPv6 payload length must be consistent.
///  - Future: allow/deny rules, port blocking, domain filtering.
export fn qpacket_filter(state: ?*anyopaque, packet: [*]const u8, len: usize) callconv(.c) c_int {
    const s: *FilterState = @ptrCast(@alignCast(state orelse return @intFromEnum(Verdict.allow)));
    s.packets_seen += 1;
    s.bytes_seen += len;

    if (len < 20) {
        s.packets_dropped += 1;
        return @intFromEnum(Verdict.drop);
    }

    const buf = packet[0..len];
    const version = buf[0] >> 4;

    if (version == 4) {
        s.packets_ipv4 += 1;
        const proto = parseIPv4(buf);
        if (proto) |p| {
            switch (p) {
                .tcp => s.packets_tcp += 1,
                .udp => s.packets_udp += 1,
                .icmp => s.packets_icmp += 1,
                else => s.packets_other += 1,
            }
        } else {
            s.packets_dropped += 1;
            return @intFromEnum(Verdict.drop);
        }
    } else if (version == 6) {
        s.packets_ipv6 += 1;
        const proto = parseIPv6(buf);
        if (proto) |p| {
            switch (p) {
                .tcp => s.packets_tcp += 1,
                .udp => s.packets_udp += 1,
                .icmpv6 => s.packets_icmp += 1,
                else => s.packets_other += 1,
            }
        } else {
            s.packets_dropped += 1;
            return @intFromEnum(Verdict.drop);
        }
    } else {
        // Unknown IP version — drop.
        s.packets_dropped += 1;
        return @intFromEnum(Verdict.drop);
    }

    return @intFromEnum(Verdict.allow);
}

/// Statistics. Both entry points read counters that only `qpacket_filter`
/// increments (from the Go tun wrapper).
export fn qpacket_filter_stats(state: ?*anyopaque, seen: *u64, dropped: *u64) callconv(.c) void {
    const s: *FilterState = @ptrCast(@alignCast(state orelse return));
    seen.* = s.packets_seen;
    dropped.* = s.packets_dropped;
}

export fn qpacket_filter_stats_extended(
    state: ?*anyopaque,
    stats: *PacketStats,
) callconv(.c) void {
    const s: *FilterState = @ptrCast(@alignCast(state orelse return));
    stats.* = .{
        .packets_seen = s.packets_seen,
        .packets_dropped = s.packets_dropped,
        .packets_tcp = s.packets_tcp,
        .packets_udp = s.packets_udp,
        .packets_icmp = s.packets_icmp,
        .packets_other = s.packets_other,
        .packets_ipv4 = s.packets_ipv4,
        .packets_ipv6 = s.packets_ipv6,
        .bytes_seen = s.bytes_seen,
    };
}

export fn qpacket_filter_deinit(state: ?*anyopaque) callconv(.c) void {
    const s: *FilterState = @ptrCast(@alignCast(state orelse return));
    std.heap.c_allocator.destroy(s);
}

// ---------- C-compatible struct for extended stats ----------

const PacketStats = extern struct {
    packets_seen: u64,
    packets_dropped: u64,
    packets_tcp: u64,
    packets_udp: u64,
    packets_icmp: u64,
    packets_other: u64,
    packets_ipv4: u64,
    packets_ipv6: u64,
    bytes_seen: u64,
};

// ---------- Tests ----------

test "filter state lifecycle" {
    const state = qpacket_filter_init();
    try std.testing.expect(state != null);

    var seen: u64 = 0;
    var dropped: u64 = 0;
    qpacket_filter_stats(state, &seen, &dropped);
    try std.testing.expectEqual(@as(u64, 0), seen);
    try std.testing.expectEqual(@as(u64, 0), dropped);

    qpacket_filter_deinit(state);
}

test "valid IPv4 TCP packet" {
    const state = qpacket_filter_init();
    defer qpacket_filter_deinit(state);

    // Build a minimal IPv4 TCP packet: 20 byte header + 20 byte TCP
    var packet: [40]u8 = .{0} ** 40;
    packet[0] = 0x45; // version=4, IHL=5 (20 bytes)
    // total length = 40 (big-endian)
    std.mem.writeInt(u16, packet[2..4], @as(u16, 40), .big);
    packet[9] = 6; // TCP protocol

    const verdict = qpacket_filter(state, &packet, packet.len);
    try std.testing.expectEqual(@as(c_int, 0), verdict);

    var seen: u64 = 0;
    var dropped: u64 = 0;
    qpacket_filter_stats(state, &seen, &dropped);
    try std.testing.expectEqual(@as(u64, 1), seen);
    try std.testing.expectEqual(@as(u64, 0), dropped);
}

test "valid IPv4 UDP packet" {
    const state = qpacket_filter_init();
    defer qpacket_filter_deinit(state);

    var packet: [28]u8 = .{0} ** 28;
    packet[0] = 0x45;
    std.mem.writeInt(u16, packet[2..4], @as(u16, 28), .big);
    packet[9] = 17; // UDP

    const verdict = qpacket_filter(state, &packet, packet.len);
    try std.testing.expectEqual(@as(c_int, 0), verdict);
}

test "valid IPv6 TCP packet" {
    const state = qpacket_filter_init();
    defer qpacket_filter_deinit(state);

    var packet: [60]u8 = .{0} ** 60;
    packet[0] = 0x60; // version=6, traffic class=0
    std.mem.writeInt(u16, packet[4..6], @as(u16, 20), .big); // payload length
    packet[6] = 6; // next header = TCP

    const verdict = qpacket_filter(state, &packet, packet.len);
    try std.testing.expectEqual(@as(c_int, 0), verdict);
}

test "packet too short" {
    const state = qpacket_filter_init();
    defer qpacket_filter_deinit(state);

    const packet = [_]u8{0x45} ** 5; // 5 bytes, less than 20
    const verdict = qpacket_filter(state, &packet, packet.len);
    try std.testing.expectEqual(@as(c_int, 1), verdict); // drop
}

test "invalid IP version" {
    const state = qpacket_filter_init();
    defer qpacket_filter_deinit(state);

    var packet: [20]u8 = .{0} ** 20;
    packet[0] = 0x30; // version=3 (invalid)
    const verdict = qpacket_filter(state, &packet, packet.len);
    try std.testing.expectEqual(@as(c_int, 1), verdict); // drop
}

test "IPv4 malformed IHL" {
    const state = qpacket_filter_init();
    defer qpacket_filter_deinit(state);

    var packet: [20]u8 = .{0} ** 20;
    packet[0] = 0x46; // version=4, IHL=6 (24 bytes, but packet is only 20)
    std.mem.writeInt(u16, packet[2..4], @as(u16, 20), .big);
    packet[9] = 6;

    const verdict = qpacket_filter(state, &packet, packet.len);
    try std.testing.expectEqual(@as(c_int, 1), verdict); // drop
}

test "IPv4 total length mismatch" {
    const state = qpacket_filter_init();
    defer qpacket_filter_deinit(state);

    var packet: [40]u8 = .{0} ** 40;
    packet[0] = 0x45;
    std.mem.writeInt(u16, packet[2..4], @as(u16, 100), .big); // claims 100, but only 40 bytes
    packet[9] = 6;

    const verdict = qpacket_filter(state, &packet, packet.len);
    try std.testing.expectEqual(@as(c_int, 1), verdict); // drop
}

test "extended stats" {
    const state = qpacket_filter_init();
    defer qpacket_filter_deinit(state);

    // Send one valid IPv4 TCP packet
    var pkt: [40]u8 = .{0} ** 40;
    pkt[0] = 0x45;
    std.mem.writeInt(u16, pkt[2..4], @as(u16, 40), .big);
    pkt[9] = 6;
    _ = qpacket_filter(state, &pkt, pkt.len);

    // Send one valid IPv4 UDP packet
    var pkt2: [28]u8 = .{0} ** 28;
    pkt2[0] = 0x45;
    std.mem.writeInt(u16, pkt2[2..4], @as(u16, 28), .big);
    pkt2[9] = 17;
    _ = qpacket_filter(state, &pkt2, pkt2.len);

    // Send one invalid packet (dropped)
    const bad = [_]u8{0x45} ** 5;
    _ = qpacket_filter(state, &bad, bad.len);

    var stats: PacketStats = undefined;
    qpacket_filter_stats_extended(state, &stats);
    try std.testing.expectEqual(@as(u64, 3), stats.packets_seen);
    try std.testing.expectEqual(@as(u64, 1), stats.packets_dropped);
    try std.testing.expectEqual(@as(u64, 1), stats.packets_tcp);
    try std.testing.expectEqual(@as(u64, 1), stats.packets_udp);
    try std.testing.expectEqual(@as(u64, 2), stats.packets_ipv4);
    try std.testing.expectEqual(@as(u64, 0), stats.packets_ipv6);
    try std.testing.expectEqual(@as(u64, 73), stats.bytes_seen); // 40 + 28 + 5
}