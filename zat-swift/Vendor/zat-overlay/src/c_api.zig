//! c_api.zig — the C ABI marshalling layer over the Explorer facade.
//!
//! THIS IS OUR CODE. It translates between the C types declared in
//! include/zat.h and the Explorer facade in explorer.zig. It is re-exported
//! (symbol-for-symbol) by c_root.zig, the root module of the `zat_c` static
//! library that the Swift wrapper links. See include/zat.h for the exact C
//! contract (status codes, ownership, absent-optional conventions) — this file
//! is the implementation of that contract.
//!
//! OWNERSHIP: every byte handed out across the boundary is allocated from the
//! C heap (`std.heap.c_allocator`, i.e. malloc) so the library can free it,
//! and it is freed ONLY through the deinit exports / zat_free. Strings are
//! NUL-terminated with `len` authoritative; absent optionals are
//! { ptr = null, len = 0 }.

const std = @import("std");
const zat = @import("zat");
const build_options = @import("build_options");
const explorer = @import("explorer.zig");

const Allocator = std.mem.Allocator;
const XrpcClient = zat.XrpcClient;

/// Memory handed to the caller. Must be malloc-backed so zat_free /
/// zat_*_deinit can release it.
const gpa = std.heap.c_allocator;

pub const Status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    invalid_identifier = 2,
    invalid_response = 3,
    missing_field = 4,
    missing_pds = 5,
    network = 6,
    out_of_memory = 7,
    unexpected = 8,
};

pub const ZatString = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,
};

pub const ZatBlob = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,
};

pub const ZatErrorDetails = extern struct {
    http_status: c_int = 0,
    error_name: ZatString = .{},
    message: ZatString = .{},
    retry_after: i64 = -1,
};

pub const ZatIdentity = extern struct {
    did: ZatString,
    handle: ZatString,
    pds: ZatString,
};

pub const ZatCarRecord = extern struct {
    path: ZatString,
    cid: ZatString,
    json: ZatString,
};

pub const ZatCarRecords = extern struct {
    records: ?[*]ZatCarRecord = null,
    count: usize = 0,
};

const Explorer = explorer.Explorer;
const FakeTransport = explorer.FakeTransport;

// ── helpers ─────────────────────────────────────────────────────────────────

fn statusFromErr(err: anyerror) Status {
    return switch (err) {
        error.InvalidArgument => .invalid_argument,
        error.InvalidIdentifier => .invalid_identifier,
        error.InvalidResponse => .invalid_response,
        error.MissingField => .missing_field,
        error.MissingPds => .missing_pds,
        error.NetworkFailure => .network,
        error.OutOfMemory => .out_of_memory,
        else => .unexpected,
    };
}

/// Copy `bytes` into a NUL-terminated, malloc-backed ZatString. `len` is the
/// byte count (excluding the terminator), matching the header contract.
fn makeString(bytes: []const u8) Allocator.Error!ZatString {
    const buf = try gpa.alloc(u8, bytes.len + 1);
    @memcpy(buf[0..bytes.len], bytes);
    buf[bytes.len] = 0;
    return .{ .ptr = buf.ptr, .len = bytes.len };
}

fn makeStringOrEmpty(bytes: ?[]const u8) Allocator.Error!ZatString {
    return if (bytes) |b| makeString(b) else .{ .ptr = null, .len = 0 };
}

fn makeBlob(bytes: []const u8) Allocator.Error!ZatBlob {
    const buf = try gpa.alloc(u8, bytes.len);
    @memcpy(buf, bytes);
    return .{ .ptr = buf.ptr, .len = bytes.len };
}

fn freeString(s: *ZatString) void {
    if (s.ptr) |p| gpa.free(p[0 .. s.len + 1]);
    s.* = .{ .ptr = null, .len = 0 };
}

fn freeBlob(b: *ZatBlob) void {
    if (b.ptr) |p| gpa.free(p[0..b.len]);
    b.* = .{ .ptr = null, .len = 0 };
}

fn zeroDetails(d: ?*ZatErrorDetails) void {
    if (d) |p| p.* = .{ .http_status = 0, .error_name = .{}, .message = .{}, .retry_after = -1 };
}

/// Fill `details` from a non-2xx XRPC envelope (XrpcError). `xerr` is the
/// `.err` payload of an `XrpcClient.Result`, passed as `anytype` so callers
/// don't need to name the upstream type. On allocation failure it abandons
/// the (unusual) OOM path, freeing any partial field.
fn fillDetails(details: ?*ZatErrorDetails, xerr: anytype) void {
    const d = details orelse return;
    d.* = .{ .http_status = 0, .error_name = .{}, .message = .{}, .retry_after = -1 };
    d.http_status = @intCast(@intFromEnum(xerr.status));
    if (xerr.error_name) |name| {
        d.error_name = makeString(name) catch {
            d.* = .{ .http_status = d.http_status, .error_name = .{}, .message = .{}, .retry_after = -1 };
            return;
        };
    }
    if (xerr.message) |msg| {
        d.message = makeString(msg) catch {
            freeString(&d.error_name);
            d.message = .{};
            return;
        };
    }
    if (xerr.rate_limit.retry_after) |secs| {
        d.retry_after = @as(i64, @intCast(secs));
    }
}

/// Shared `Result` marshalling for the JSON-returning network calls: on a 2xx
/// response copy the body to `out` (details zeroed); on a non-2xx envelope
/// zero `out`, fill `details`, and report the envelope as invalid_response.
fn writeResultJson(res: XrpcClient.Result, out: *ZatString, details: ?*ZatErrorDetails) Status {
    switch (res) {
        .ok => |response| {
            out.* = makeString(response.body) catch {
                zeroDetails(details);
                return .out_of_memory;
            };
            zeroDetails(details);
            return .ok;
        },
        .err => |xerr| {
            out.* = .{ .ptr = null, .len = 0 };
            fillDetails(details, xerr);
            return .invalid_response;
        },
    }
}

fn writeResultCar(res: XrpcClient.Result, out: *ZatBlob, details: ?*ZatErrorDetails) Status {
    switch (res) {
        .ok => |response| {
            out.* = makeBlob(response.body) catch {
                zeroDetails(details);
                return .out_of_memory;
            };
            zeroDetails(details);
            return .ok;
        },
        .err => |xerr| {
            out.* = .{ .ptr = null, .len = 0 };
            fillDetails(details, xerr);
            return .invalid_response;
        },
    }
}

fn explorerFromRaw(raw: ?*anyopaque) ?*Explorer {
    return @ptrCast(@alignCast(raw orelse return null));
}

// ── version / free ──────────────────────────────────────────────────────────

pub fn zat_version() callconv(.c) [*:0]const u8 {
    // Tracks build.zig.zon automatically via the build_options module
    // (wired in build.zig) — no manual bump needed on upstream updates.
    return build_options.version;
}

pub fn zat_free(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| std.c.free(p);
}

// ── explorer lifecycle ──────────────────────────────────────────────────────

pub fn zat_explorer_create(host: ?[*:0]const u8, out: ?*?*anyopaque) callconv(.c) Status {
    return explorerCreateImpl(host, null, out);
}

pub fn zat_explorer_create_with_fake(host: ?[*:0]const u8, fake_raw: ?*anyopaque, out: ?*?*anyopaque) callconv(.c) Status {
    return explorerCreateImpl(host, fake_raw, out);
}

fn explorerCreateImpl(host: ?[*:0]const u8, fake_raw: ?*anyopaque, out: ?*?*anyopaque) Status {
    const outp = out orelse return .invalid_argument;
    outp.* = null;
    const hs = if (host) |h| std.mem.span(h) else "";
    const fake: ?*FakeTransport = if (fake_raw) |f| @ptrCast(@alignCast(f)) else null;
    const ex = Explorer.createWithFake(gpa, hs, fake) catch |err| return statusFromErr(err);
    outp.* = @ptrCast(ex);
    return .ok;
}

pub fn zat_explorer_destroy(exp: ?*anyopaque) callconv(.c) void {
    if (explorerFromRaw(exp)) |ex| ex.destroy();
}

// ── identity ────────────────────────────────────────────────────────────────

pub fn zat_resolve_identity(exp: ?*anyopaque, identifier: ?[*:0]const u8, out: ?*ZatIdentity) callconv(.c) Status {
    const ex = explorerFromRaw(exp) orelse return .invalid_argument;
    const outp = out orelse return .invalid_argument;
    outp.* = .{ .did = .{}, .handle = .{}, .pds = .{} };
    const ident = (identifier orelse return .invalid_argument);
    var result = ex.resolveIdentity(std.mem.span(ident)) catch |err| return statusFromErr(err);
    defer result.deinit(gpa);

    outp.did = makeString(result.did) catch {
        outp.* = .{ .did = .{}, .handle = .{}, .pds = .{} };
        return .out_of_memory;
    };
    outp.handle = makeStringOrEmpty(result.handle) catch {
        freeString(&outp.did);
        outp.* = .{ .did = .{}, .handle = .{}, .pds = .{} };
        return .out_of_memory;
    };
    outp.pds = makeStringOrEmpty(result.pds) catch {
        freeString(&outp.did);
        freeString(&outp.handle);
        outp.* = .{ .did = .{}, .handle = .{}, .pds = .{} };
        return .out_of_memory;
    };
    return .ok;
}

pub fn zat_identity_deinit(id: ?*ZatIdentity) callconv(.c) void {
    const p = id orelse return;
    freeString(&p.did);
    freeString(&p.handle);
    freeString(&p.pds);
    p.* = .{ .did = .{}, .handle = .{}, .pds = .{} };
}

pub fn zat_string_deinit(s: ?*ZatString) callconv(.c) void {
    if (s) |p| freeString(p);
}

pub fn zat_blob_deinit(b: ?*ZatBlob) callconv(.c) void {
    if (b) |p| freeBlob(p);
}

pub fn zat_error_details_deinit(d: ?*ZatErrorDetails) callconv(.c) void {
    const p = d orelse return;
    freeString(&p.error_name);
    freeString(&p.message);
    p.* = .{ .http_status = 0, .error_name = .{}, .message = .{}, .retry_after = -1 };
}

// ── XRPC reads ──────────────────────────────────────────────────────────────

pub fn zat_get_record_json(exp: ?*anyopaque, at_uri: ?[*:0]const u8, out: ?*ZatString, details: ?*ZatErrorDetails) callconv(.c) Status {
    const ex = explorerFromRaw(exp) orelse return .invalid_argument;
    const outp = out orelse return .invalid_argument;
    outp.* = .{ .ptr = null, .len = 0 };
    const uri = (at_uri orelse return .invalid_argument);
    var res = ex.getRecordJson(std.mem.span(uri)) catch |err| {
        zeroDetails(details);
        return statusFromErr(err);
    };
    defer res.deinit();
    return writeResultJson(res, outp, details);
}

pub fn zat_list_records_json(
    exp: ?*anyopaque,
    repo: ?[*:0]const u8,
    collection: ?[*:0]const u8,
    limit: u32,
    cursor: ?[*:0]const u8,
    out: ?*ZatString,
    details: ?*ZatErrorDetails,
) callconv(.c) Status {
    const ex = explorerFromRaw(exp) orelse return .invalid_argument;
    const outp = out orelse return .invalid_argument;
    outp.* = .{ .ptr = null, .len = 0 };
    const repo_span = (repo orelse return .invalid_argument);
    const collection_span = (collection orelse return .invalid_argument);
    const cursor_opt: ?[]const u8 = if (cursor) |c| std.mem.span(c) else null;
    var res = ex.listRecordsJson(std.mem.span(repo_span), std.mem.span(collection_span), limit, cursor_opt) catch |err| {
        zeroDetails(details);
        return statusFromErr(err);
    };
    defer res.deinit();
    return writeResultJson(res, outp, details);
}

pub fn zat_describe_repo_json(exp: ?*anyopaque, repo: ?[*:0]const u8, out: ?*ZatString, details: ?*ZatErrorDetails) callconv(.c) Status {
    const ex = explorerFromRaw(exp) orelse return .invalid_argument;
    const outp = out orelse return .invalid_argument;
    outp.* = .{ .ptr = null, .len = 0 };
    const repo_span = (repo orelse return .invalid_argument);
    var res = ex.describeRepoJson(std.mem.span(repo_span)) catch |err| {
        zeroDetails(details);
        return statusFromErr(err);
    };
    defer res.deinit();
    return writeResultJson(res, outp, details);
}

pub fn zat_fetch_repo_car(exp: ?*anyopaque, did: ?[*:0]const u8, out: ?*ZatBlob, details: ?*ZatErrorDetails) callconv(.c) Status {
    const ex = explorerFromRaw(exp) orelse return .invalid_argument;
    const outp = out orelse return .invalid_argument;
    outp.* = .{ .ptr = null, .len = 0 };
    const did_span = (did orelse return .invalid_argument);
    var res = ex.fetchRepoCar(std.mem.span(did_span)) catch |err| {
        zeroDetails(details);
        return statusFromErr(err);
    };
    defer res.deinit();
    return writeResultCar(res, outp, details);
}

// ── CAR record iteration ────────────────────────────────────────────────────

pub fn zat_iterate_car_records(car_bytes: ?[*]const u8, car_len: usize, out: ?*?*ZatCarRecords) callconv(.c) Status {
    const outp = out orelse return .invalid_argument;
    outp.* = null;
    const bytes: []const u8 = if (car_bytes) |p| p[0..car_len] else return .invalid_argument;

    var records = explorer.iterateCarRecords(gpa, bytes) catch |err| return statusFromErr(err);
    defer records.deinit();

    const car_recs = gpa.create(ZatCarRecords) catch return .out_of_memory;
    const arr = gpa.alloc(ZatCarRecord, records.records.len) catch {
        gpa.destroy(car_recs);
        return .out_of_memory;
    };
    car_recs.* = .{ .records = arr.ptr, .count = records.records.len };

    for (records.records, 0..) |src, i| {
        arr[i] = .{ .path = .{}, .cid = .{}, .json = .{} };
        arr[i].path = makeString(src.path) catch {
            destroyCarRecordsPartial(car_recs, i + 1);
            return .out_of_memory;
        };
        arr[i].cid = makeString(src.cid) catch {
            destroyCarRecordsPartial(car_recs, i + 1);
            return .out_of_memory;
        };
        arr[i].json = makeString(src.json) catch {
            destroyCarRecordsPartial(car_recs, i + 1);
            return .out_of_memory;
        };
    }

    outp.* = car_recs;
    return .ok;
}

pub fn zat_car_records_deinit(records: ?*ZatCarRecords) callconv(.c) void {
    const cr = records orelse return;
    destroyCarRecordsPartial(cr, cr.count);
}

/// Free the first `filled` records of `cr` plus the backing array, and then
/// destroy the struct itself. The struct is freed exactly once, last, so no
/// caller writes to it afterwards. Safe on partially-initialized listings:
/// never-filled fields are the `{}` zero value, and freeString zeroes as it
/// goes.
fn destroyCarRecordsPartial(cr: *ZatCarRecords, filled: usize) void {
    freeCarRecordsContents(cr, filled);
    gpa.destroy(cr);
}

fn freeCarRecordsContents(cr: *ZatCarRecords, filled: usize) void {
    if (cr.records) |p| {
        for (p[0..filled]) |*rec| {
            freeString(&rec.path);
            freeString(&rec.cid);
            freeString(&rec.json);
        }
    }
    if (cr.records) |p| gpa.free(p[0..cr.count]);
}

// ── fake transport ──────────────────────────────────────────────────────────

pub fn zat_fake_transport_create(out: ?*?*anyopaque) callconv(.c) Status {
    const outp = out orelse return .invalid_argument;
    outp.* = null;
    const fake = FakeTransport.create(gpa) catch |err| return statusFromErr(err);
    outp.* = @ptrCast(fake);
    return .ok;
}

pub fn zat_fake_transport_destroy(fake_raw: ?*anyopaque) callconv(.c) void {
    if (fake_raw) |f| {
        const fake: *FakeTransport = @ptrCast(@alignCast(f));
        fake.destroy();
    }
}

pub fn zat_fake_transport_queue_response(fake_raw: ?*anyopaque, status: c_int, body: ?[*:0]const u8, retry_after_seconds: c_int) callconv(.c) Status {
    const fake: *FakeTransport = @ptrCast(@alignCast(fake_raw orelse return .invalid_argument));
    const body_span = if (body) |b| std.mem.span(b) else "";
    const http_status: std.http.Status = @enumFromInt(@as(u16, @intCast(status)));
    const retry: ?u64 = if (retry_after_seconds < 0) null else @as(u64, @intCast(retry_after_seconds));
    fake.queueResponse(http_status, body_span, retry) catch |err| return statusFromErr(err);
    return .ok;
}

pub fn zat_fake_transport_request_count(fake_raw: ?*anyopaque) callconv(.c) usize {
    const fake: *FakeTransport = @ptrCast(@alignCast(fake_raw orelse return 0));
    return fake.requestCount();
}

pub fn zat_fake_transport_last_url(fake_raw: ?*anyopaque, out: ?*ZatString) callconv(.c) Status {
    const fake: *FakeTransport = @ptrCast(@alignCast(fake_raw orelse return .invalid_argument));
    const outp = out orelse return .invalid_argument;
    outp.* = .{ .ptr = null, .len = 0 };
    const url = fake.lastUrl() catch |err| return statusFromErr(err);
    outp.* = makeString(url) catch return .out_of_memory;
    return .ok;
}