//! explorer.zig — the Explorer facade: reader-facing operations over upstream
//! zat primitives (syntax, identity resolution, XRPC, CAR/MST/DAG-CBOR).
//!
//! This is OUR code, layered on top of the zat kit (see
//! zat-swift/Vendor/zat-overlay/README.md). It backs the C ABI (c_api.zig);
//! the Swift wrapper calls through. Three responsibilities:
//!
//!   1. Session (Exorrler) bound to a host, with an optional scripted
//!      transport (FakeTransport) injected for deterministic tests.
//!   2. Reader XRPC calls: getRecord / listRecords / describeRepo / getRepo
//!      (raw JSON bodies and CAR bytes out), each surfacing a non-2xx XRPC
//!      envelope as `XrpcClient.Result.err` and transport failures as
//!      `error.NetworkFailure`.
//!   3. CAR record iteration, fully offline: walk the commit block + MST +
//!      record blocks and emit { path: "collection/rkey", cid: multibase,
//!      json } per record.
const std = @import("std");
const zat = @import("zat");

const Allocator = std.mem.Allocator;
const Did = zat.Did;
const Handle = zat.Handle;
const Nsid = zat.Nsid;
const AtUri = zat.AtUri;
const DidResolver = zat.DidResolver;
const HandleResolver = zat.HandleResolver;
const XrpcClient = zat.XrpcClient;

// Canonical errors the C ABI maps onto `zat_status`. Everything else thrown
// from the transport layer is collapsed to NetworkFailure here.
pub const ExplorerError = error{
    InvalidIdentifier,
    InvalidArgument,
    MissingField,
    MissingPds,
    NetworkFailure,
    OutOfMemory,
    InvalidResponse,
};

/// Identity resolution result: did (always), plus optional handle + PDS.
pub const ResolvedIdentity = struct {
    did: []u8,
    handle: ?[]u8,
    pds: ?[]u8,

    pub fn deinit(self: *ResolvedIdentity, allocator: Allocator) void {
        allocator.free(self.did);
        if (self.handle) |h| allocator.free(h);
        if (self.pds) |p| allocator.free(p);
        self.* = undefined;
    }
};

/// One record decoded from a repo CAR (see `iterateCarRecords`).
pub const CarRecord = struct {
    path: []u8, // "collection/rkey"
    cid: []u8, // multibase CID string, e.g. "bafy…"
    json: []u8, // record body as JSON text
};

/// A decoded record listing from a CAR, in MST key order.
pub const CarRecords = struct {
    allocator: Allocator,
    records: []CarRecord,

    pub fn deinit(self: *CarRecords) void {
        for (self.records) |record| {
            self.allocator.free(record.path);
            self.allocator.free(record.cid);
            self.allocator.free(record.json);
        }
        self.allocator.free(self.records);
        self.* = undefined;
    }
};

const max_car_blocks: usize = 1_000_000;

/// Decode every record of a full repo CAR (commit block + MST walk + record
/// blocks, all DAG-CBOR) into an owned listing. Fully offline. `car_bytes`
/// are the raw CAR (e.g. from `fetchRepoCar`); the caller keeps ownership and
/// frees the result with `CarRecords.deinit`.
pub fn iterateCarRecords(allocator: Allocator, car_bytes: []const u8) ExplorerError!CarRecords {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No fixed 2 MB cap: the mirror flow decodes arbitrarily large repos.
    var options = zat.car.ReadOptions{};
    options.max_size = car_bytes.len;
    options.max_blocks = max_car_blocks;
    const repo_car = zat.car.readWithOptions(a, car_bytes, options) catch return error.InvalidResponse;

    // Commit block → MST root (data CID). Mirrors `loadCommitFromCAR` but
    // without its size cap so big repos decode too.
    if (repo_car.roots.len == 0) return error.InvalidResponse;
    const commit_block = zat.car.findBlock(repo_car, repo_car.roots[0].raw) orelse return error.InvalidResponse;
    const commit_value = zat.cbor.decodeAll(a, commit_block) catch return error.InvalidResponse;
    const data_cid = switch (commit_value.get("data") orelse return error.InvalidResponse) {
        .cid => |c| c.raw,
        else => return error.InvalidResponse,
    };

    var tree = zat.mst.Mst.loadFromBlocks(a, repo_car, data_cid) catch return error.InvalidResponse;
    var ctx = WalkCtx{ .allocator = a, .car = repo_car, .records = .empty };
    tree.walk(.{ .ctx = &ctx, .entryFn = WalkCtx.onEntry }) catch return error.InvalidResponse;

    const records = try allocator.alloc(CarRecord, ctx.records.items.len);
    errdefer {
        for (records[0..]) |record| {
            allocator.free(record.path);
            allocator.free(record.cid);
            allocator.free(record.json);
        }
        allocator.free(records);
    }
    for (records, ctx.records.items) |*dst, src| {
        dst.path = try allocator.dupe(u8, src.path);
        dst.cid = try allocator.dupe(u8, src.cid);
        dst.json = try allocator.dupe(u8, src.json);
    }
    return .{ .allocator = allocator, .records = records };
}

const WalkCtx = struct {
    allocator: Allocator,
    car: zat.car.Car,
    records: std.ArrayList(CarRecord),

    /// Walker entryFn shim: Mst.walk calls back with `*anyopaque` ctx; we
    /// recover the typed context here (the tree was built for our ctx).
    fn onEntry(raw: *anyopaque, entry: zat.mst.WalkEntry) anyerror!void {
        const ctx: *WalkCtx = @ptrCast(@alignCast(raw));
        return onEntryImpl(ctx, entry);
    }

    fn onEntryImpl(ctx: *WalkCtx, entry: zat.mst.WalkEntry) anyerror!void {
        const block = zat.car.findBlock(ctx.car, entry.value.raw) orelse return error.MissingRecordBlock;
        const record = zat.cbor.decodeAll(ctx.allocator, block) catch return error.InvalidRecord;
        const json_str = try cborToJson(ctx.allocator, record);
        try ctx.records.append(ctx.allocator, .{
            .path = try ctx.allocator.dupe(u8, entry.key),
            .cid = try entry.value.toString(ctx.allocator),
            .json = json_str,
        });
    }
};

// ── CBOR → JSON ─────────────────────────────────────────────────────────────
// The atproto convention serializes DAG-CBOR links and bytes to JSON objects
// rather than lossy primitives: CIDs become {"$link": "bafy…"}, byte strings
// become {"$bytes": "<base64>"}. Everything else maps to plain JSON and
// round-trips through Foundation's JSONDecoder on the Swift side.

fn cborToJson(allocator: Allocator, root: zat.cbor.Value) anyerror![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try writeValue(allocator, &out, root);
    return out.toOwnedSlice(allocator);
}

fn writeValue(allocator: Allocator, out: *std.ArrayList(u8), value: zat.cbor.Value) anyerror!void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .boolean => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .unsigned => |u| try out.print(allocator, "{d}", .{u}),
        .negative => |n| try out.print(allocator, "{d}", .{n}),
        .float => |f| try writeFloat(allocator, out, f),
        .text => |s| try writeString(allocator, out, s),
        .bytes => |b| {
            const enc = std.base64.standard.Encoder;
            const size = enc.calcSize(b.len);
            const slice = try allocator.alloc(u8, size);
            defer allocator.free(slice);
            const encoded = enc.encode(slice, b);
            try out.appendSlice(allocator, "{\"$bytes\":\"");
            try writeRawString(allocator, out, encoded);
            try out.appendSlice(allocator, "\"}");
        },
        .cid => |c| {
            const s = try c.toString(allocator);
            defer allocator.free(s);
            try out.appendSlice(allocator, "{\"$link\":\"");
            try writeRawString(allocator, out, s);
            try out.appendSlice(allocator, "\"}");
        },
        .array => |arr| {
            try out.append(allocator, '[');
            for (arr, 0..) |item, i| {
                if (i != 0) try out.append(allocator, ',');
                try writeValue(allocator, out, item);
            }
            try out.append(allocator, ']');
        },
        .map => |entries| {
            try out.append(allocator, '{');
            for (entries, 0..) |entry, i| {
                if (i != 0) try out.append(allocator, ',');
                try writeString(allocator, out, entry.key);
                try out.append(allocator, ':');
                try writeValue(allocator, out, entry.value);
            }
            try out.append(allocator, '}');
        },
    }
}

fn writeFloat(allocator: Allocator, out: *std.ArrayList(u8), value: f64) anyerror!void {
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch {
        try out.print(allocator, "{d}", .{value});
        return;
    };
    try out.appendSlice(allocator, s);
}

fn writeString(allocator: Allocator, out: *std.ArrayList(u8), s: []const u8) anyerror!void {
    try out.append(allocator, '"');
    try writeRawString(allocator, out, s);
    try out.append(allocator, '"');
}

fn writeRawString(allocator: Allocator, out: *std.ArrayList(u8), s: []const u8) anyerror!void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\x08' => try out.appendSlice(allocator, "\\b"),
            '\x0c' => try out.appendSlice(allocator, "\\f"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => if (c < 0x20) try out.print(allocator, "\\u{x:0>4}", .{c}) else try out.append(allocator, c),
        }
    }
}

// ── Fake transport ──────────────────────────────────────────────────────────
// A scripted XRPC transport for deterministic tests: responses are served
// FIFO, requests are recorded (count, last URL), and 429s retry per
// Retry-After (0 = instantly, no sleeping). Mirrors the XRPC client's retry
// policy so offline tests exercise the same code path as live calls.

pub const FakeTransport = struct {
    allocator: Allocator,
    threaded: std.Io.Threaded,
    io: std.Io,
    queue: std.ArrayList(Queued),
    request_count: usize = 0,
    last_url: ?[]u8 = null,

    const Queued = struct {
        status: std.http.Status,
        body: []u8,
        retry_after: ?u64,
    };

    pub fn create(allocator: Allocator) !*FakeTransport {
        const self = try allocator.create(FakeTransport);
        // Full struct literal: the field defaults for request_count / last_url
        // apply here (they would be garbage if the fields were assigned one by
        // one onto uninitialized memory from allocator.create).
        var threaded = std.Io.Threaded.init(allocator, .{});
        self.* = .{
            .allocator = allocator,
            .threaded = threaded,
            .io = threaded.io(),
            .queue = .empty,
        };
        return self;
    }

    pub fn destroy(self: *FakeTransport) void {
        for (self.queue.items) |q| self.allocator.free(q.body);
        self.queue.deinit(self.allocator);
        if (self.last_url) |u| self.allocator.free(u);
        self.threaded.deinit();
        self.allocator.destroy(self);
    }

    pub fn queueResponse(self: *FakeTransport, status: std.http.Status, body: []const u8, retry_after: ?u64) Allocator.Error!void {
        try self.queue.append(self.allocator, .{
            .status = status,
            .body = try self.allocator.dupe(u8, body),
            .retry_after = retry_after,
        });
    }

    pub fn requestCount(self: *const FakeTransport) usize {
        return self.request_count;
    }

    /// URL of the most recent request (borrowed; the caller dupes as needed).
    /// `error.InvalidArgument` before any request has been served.
    pub fn lastUrl(self: *const FakeTransport) error{ InvalidArgument }![]const u8 {
        return self.last_url orelse error.InvalidArgument;
    }

    /// Run a checked (retry + envelope) GET against the script, returning the
    /// same Result shape as `XrpcClient.queryParamsChecked`.
    pub fn checkedUrl(self: *FakeTransport, allocator: Allocator, url: []const u8, retry: XrpcClient.RetryPolicy) !XrpcClient.Result {
        const attempts = @max(@as(u8, 1), retry.max_attempts);
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            var response = self.respond(allocator, url) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.Unexpected,
            };
            if (response.ok()) return .{ .ok = response };
            if (attempt + 1 < attempts and retry.isRetryableStatusForMethod(.GET, response.status)) {
                const rate_limit = response.rate_limit;
                response.deinit();
                try retry.sleepBeforeRetry(self.io, attempt, rate_limit);
                continue;
            }
            return .{ .err = try XrpcClient.XrpcError.fromResponse(response) };
        }
    }

    fn respond(self: *FakeTransport, allocator: Allocator, url: []const u8) !XrpcClient.Response {
        if (self.queue.items.len == 0) return error.NoResponseQueued;
        self.request_count += 1;
        if (self.last_url) |u| allocator.free(u);
        self.last_url = try allocator.dupe(u8, url);
        const q = self.queue.orderedRemove(0);
        return .{
            .allocator = allocator,
            .status = q.status,
            .body = q.body,
            .rate_limit = if (q.retry_after) |s| .{ .retry_after = s } else .{},
        };
    }
};

// ── Explorer session ────────────────────────────────────────────────────────

pub const Explorer = struct {
    allocator: Allocator,
    threaded: std.Io.Threaded,
    io: std.Io,
    /// Base URL (e.g. "https://bsky.social"); owned.
    host: []u8,
    xrpc: XrpcClient,
    did_resolver: DidResolver,
    handle_resolver: HandleResolver,
    fake: ?*FakeTransport,

    pub fn create(allocator: Allocator, host: []const u8) !*Explorer {
        return createWithFake(allocator, host, null);
    }

    pub fn createWithFake(allocator: Allocator, host: []const u8, fake: ?*FakeTransport) !*Explorer {
        const self = try allocator.create(Explorer);
        self.allocator = allocator;
        self.threaded = std.Io.Threaded.init(allocator, .{});
        self.io = self.threaded.io();
        self.fake = fake;
        self.host = allocator.dupe(u8, host) catch |err| {
            self.threaded.deinit();
            allocator.destroy(self);
            return err;
        };
        self.xrpc = XrpcClient.init(self.io, allocator, self.host);
        self.did_resolver = DidResolver.init(self.io, allocator);
        self.handle_resolver = HandleResolver.init(self.io, allocator);
        return self;
    }

    pub fn destroy(self: *Explorer) void {
        self.xrpc.deinit();
        self.did_resolver.deinit();
        self.handle_resolver.deinit();
        self.allocator.free(self.host);
        self.threaded.deinit();
        self.allocator.destroy(self);
    }

    // MARK: identity

    pub fn resolveIdentity(self: *Explorer, identifier: []const u8) ExplorerError!ResolvedIdentity {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var doc = if (Did.parse(identifier)) |did|
            (self.did_resolver.resolve(did) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NetworkFailure,
            })
        else if (Handle.parse(identifier)) |handle|
            try self.resolveHandleDoc(handle)
        else
            return error.InvalidIdentifier;
        defer doc.deinit();

        const did_text = try a.dupe(u8, doc.id);
        const handle_text: ?[]u8 = blk: {
            if (Did.parse(identifier) != null) {
                // Resolved by DID: report the document's primary handle (if any).
                break :blk if (doc.handle()) |h| try a.dupe(u8, h) else null;
            } else {
                // Resolved by handle: report the input handle.
                break :blk try a.dupe(u8, identifier);
            }
        };
        const pds_text: ?[]u8 = if (doc.pdsEndpoint()) |p| try a.dupe(u8, p) else null;

        return .{
            .did = try self.allocator.dupe(u8, did_text),
            .handle = if (handle_text) |h| try self.allocator.dupe(u8, h) else null,
            .pds = if (pds_text) |p| try self.allocator.dupe(u8, p) else null,
        };
    }

    /// Resolve a handle to its DID document. Storage is owned by the
    /// resolver (self.allocator); the caller deinits the returned doc.
    fn resolveHandleDoc(self: *Explorer, handle: Handle) ExplorerError!zat.DidDocument {
        const did_str = self.handle_resolver.resolve(handle) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NetworkFailure,
        };
        defer self.allocator.free(did_str);
        const did = Did.parse(did_str) orelse return error.InvalidResponse;
        return self.did_resolver.resolve(did) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NetworkFailure,
        };
    }

    // MARK: XRPC reads

    pub fn getRecordJson(self: *Explorer, at_uri: []const u8) ExplorerError!XrpcClient.Result {
        // com.atproto.repo.getRecord's lexicon params are repo / collection /
        // rkey (no `uri` alias despite the convenience in some SDKs — the
        // reference PDS rejects a bare `uri`). Decompose the at:// URI here.
        const uri = AtUri.parse(at_uri) orelse return error.InvalidIdentifier;
        const prefix = "at://";
        const repo = uri.raw[prefix.len..uri.authority_end];
        const collection = uri.raw[uri.authority_end + 1 .. uri.collection_end];
        const rkey = uri.raw[uri.collection_end + 1 ..];
        const params = [_]XrpcClient.QueryParam{
            .{ .name = "repo", .value = repo },
            .{ .name = "collection", .value = collection },
            .{ .name = "rkey", .value = rkey },
        };
        return self.queryChecked("com.atproto.repo.getRecord", &params);
    }

    pub fn listRecordsJson(self: *Explorer, repo: []const u8, collection: []const u8, limit: u32, cursor: ?[]const u8) ExplorerError!XrpcClient.Result {
        if (Did.parse(repo) == null and Handle.parse(repo) == null) return error.InvalidIdentifier;
        _ = Nsid.parse(collection) orelse return error.InvalidIdentifier;

        var params: [4]XrpcClient.QueryParam = undefined;
        var n: usize = 0;
        params[n] = .{ .name = "repo", .value = repo };
        n += 1;
        params[n] = .{ .name = "collection", .value = collection };
        n += 1;
        if (limit != 0) {
            var buf: [16]u8 = undefined;
            const limit_str = std.fmt.bufPrint(&buf, "{d}", .{limit}) catch return error.NetworkFailure;
            params[n] = .{ .name = "limit", .value = limit_str };
            n += 1;
        }
        if (cursor) |c| {
            params[n] = .{ .name = "cursor", .value = c };
            n += 1;
        }
        return self.queryChecked("com.atproto.repo.listRecords", params[0..n]);
    }

    pub fn describeRepoJson(self: *Explorer, repo: []const u8) ExplorerError!XrpcClient.Result {
        if (Did.parse(repo) == null and Handle.parse(repo) == null) return error.InvalidIdentifier;
        const params = [_]XrpcClient.QueryParam{.{ .name = "repo", .value = repo }};
        return self.queryChecked("com.atproto.repo.describeRepo", &params);
    }

    pub fn fetchRepoCar(self: *Explorer, did: []const u8) ExplorerError!XrpcClient.Result {
        if (Did.parse(did) == null) return error.InvalidIdentifier;
        const params = [_]XrpcClient.QueryParam{
            .{ .name = "did", .value = did },
            .{ .name = "format", .value = "car" },
        };
        return self.queryChecked("com.atproto.sync.getRepo", &params);
    }

    fn queryChecked(self: *Explorer, nsid_str: []const u8, params: []const XrpcClient.QueryParam) ExplorerError!XrpcClient.Result {
        const nsid = Nsid.parse(nsid_str) orelse return error.InvalidIdentifier;
        const retry = XrpcClient.RetryPolicy{};
        if (self.fake) |fake| {
            const url = try self.buildUrl(nsid, params);
            defer self.allocator.free(url);
            return fake.checkedUrl(self.allocator, url, retry) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NetworkFailure,
            };
        }
        return self.xrpc.queryParamsChecked(nsid, params, retry) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NetworkFailure,
        };
    }

    /// Mirror of XrpcClient.buildUrlFromParams, used for the fake path so the
    /// two URLs are byte-identical (pinned by ZatFakeTransportTests).
    fn buildUrl(self: *Explorer, nsid: Nsid, params: []const XrpcClient.QueryParam) ![]u8 {
        var url: std.ArrayList(u8) = .empty;
        errdefer url.deinit(self.allocator);
        try url.appendSlice(self.allocator, self.host);
        try url.appendSlice(self.allocator, "/xrpc/");
        try url.appendSlice(self.allocator, nsid.str());
        for (params, 0..) |p, i| {
            try url.append(self.allocator, if (i == 0) '?' else '&');
            try url.appendSlice(self.allocator, p.name);
            try url.append(self.allocator, '=');
            for (p.value) |c| {
                if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
                    try url.append(self.allocator, c);
                } else {
                    try url.print(self.allocator, "%{X:0>2}", .{c});
                }
            }
        }
        return url.toOwnedSlice(self.allocator);
    }
};