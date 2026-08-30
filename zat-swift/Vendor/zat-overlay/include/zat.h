#ifndef ZAT_H
#define ZAT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * zat C ABI — a minimal boundary over the zat AT Protocol explorer core.
 *
 * OWNERSHIP CONTRACT
 * ------------------
 * 1. Every function returns zat_status. Out-parameters are written ONLY when
 *    ZAT_OK is returned; on error they are zeroed. The one exception is the
 *    zat_error_details *details out-param of the network calls below: it is
 *    zeroed on success and on errors that never reached the network, and
 *    written (never zeroed) when a non-2xx HTTP response carried an error
 *    envelope. Pass NULL to ignore details entirely.
 * 2. All memory handed out (strings, blobs, identity fields) is allocated by
 *    the library from the C heap. Release it ONLY through the library:
 *       - zat_free(ptr)                        raw pointer form
 *       - zat_string_deinit(zat_string *)      frees + zeroes
 *       - zat_blob_deinit(zat_blob *)
 *       - zat_identity_deinit(zat_identity *)  frees all three fields
 *    Never call free() directly, even though the underlying allocator is
 *    malloc's.
 * 3. Strings are NUL-terminated for convenience (String(cString:) works),
 *    but `len` is authoritative; prefer it with
 *    String(decoding:as:) / Data(bytes:count:).
 * 4. Absent optional values are { ptr = NULL, len = 0 } (e.g. a DID document
 *    without a PDS yields pds = {NULL, 0}). Every free helper accepts NULL
 *    and is a no-op.
 * 5. A zat_explorer handle is NOT thread-safe. Use one handle per thread or
 *    serialize access externally. Values returned from calls are plain heap
 *    memory and may be passed between threads freely.
 * 6. Identifiers (handles, DIDs, NSIDs, AT-URIs) are validated inside the
 *    library before any network activity; malformed input returns
 *    ZAT_ERROR_INVALID_IDENTIFIER without touching the network.
 * 7. Only free pointers that this API handed out.
 */

typedef enum zat_status {
    ZAT_OK = 0,
    ZAT_ERROR_INVALID_ARGUMENT = 1,
    ZAT_ERROR_INVALID_IDENTIFIER = 2,
    ZAT_ERROR_INVALID_RESPONSE = 3,
    ZAT_ERROR_MISSING_FIELD = 4,
    ZAT_ERROR_MISSING_PDS = 5,
    ZAT_ERROR_NETWORK = 6,
    ZAT_ERROR_OUT_OF_MEMORY = 7,
    ZAT_ERROR_UNEXPECTED = 8
} zat_status;

/* A library-owned UTF-8 string. NUL-terminated; len excludes the terminator. */
typedef struct zat_string {
    const char *ptr; /* NULL when the value is absent */
    size_t len;
} zat_string;

/* A library-owned byte buffer (binary payloads, e.g. CAR files). */
typedef struct zat_blob {
    const void *ptr;
    size_t len;
} zat_blob;

/*
 * XRPC error envelope for a failed network call. Written on every non-ok
 * status from the network exports below; zeroed on success and on errors
 * that never reached the network (validation failures carry no envelope).
 * error_name / message come from the JSON envelope body and may be {NULL, 0}
 * when the body is not JSON; http_status is the HTTP status code (e.g. 400,
 * 429) or 0 when no HTTP response was received; retry_after is the
 * Retry-After header in seconds, or -1 when absent. Release with
 * zat_error_details_deinit.
 */
typedef struct zat_error_details {
    int http_status;
    zat_string error_name;
    zat_string message;
    int64_t retry_after;
} zat_error_details;

/* Identity resolution result. Absent fields are {NULL, 0}. */
typedef struct zat_identity {
    zat_string did;    /* always present on success */
    zat_string handle; /* primary handle from the DID document, if any */
    zat_string pds;    /* repo host advertised by the DID document, if any */
} zat_identity;

/* Opaque explorer session. */
typedef struct zat_explorer zat_explorer;

/* Human-readable zat core version. Static; never freed. */
const char *zat_version(void);

/* Release any pointer handed out by this API. NULL is a no-op. */
void zat_free(void *ptr);

/*
 * Create an explorer session pointed at a host that serves the public
 * bootstrap reads (e.g. "https://bsky.social"). `host` is copied; the caller
 * may free it immediately after the call. On success *out is set and must be
 * released with zat_explorer_destroy.
 */
zat_status zat_explorer_create(const char *host, zat_explorer **out);

/* Destroy a session created by zat_explorer_create. */
void zat_explorer_destroy(zat_explorer *explorer);

/*
 * Resolve a handle or DID to {did, handle, pds} via the AT Protocol identity
 * chain (DNS-over-HTTPS / well-known handles, PLC / did:web documents).
 * Caller owns the result; release with zat_identity_deinit. Use
 * ZAT_ERROR_MISSING_PDS's sibling rule: pds may legitimately be absent for
 * foreign DID documents, so treat {NULL, 0} as "unknown", not failure.
 */
zat_status zat_resolve_identity(zat_explorer *explorer, const char *identifier, zat_identity *out);

/* Free all strings inside a zat_identity and zero it. */
void zat_identity_deinit(zat_identity *identity);

/* Free + zero a single zat_string / zat_blob returned by this API. */
void zat_string_deinit(zat_string *string);
void zat_blob_deinit(zat_blob *blob);

/* Free + zero a zat_error_details returned by a failed network call. */
void zat_error_details_deinit(zat_error_details *details);

/*
 * One record decoded from a repo CAR: its MST path ("collection/rkey"), the
 * multibase CID string of its block, and the record body as JSON. All
 * strings are library-owned; release with zat_car_records_deinit.
 */
typedef struct zat_car_record {
    zat_string path;
    zat_string cid;
    zat_string json;
} zat_car_record;

/*
 * A decoded record listing from a repo CAR (see zat_iterate_car_records).
 * Records are in MST key order. Release with zat_car_records_deinit.
 */
typedef struct zat_car_records {
    zat_car_record *records;
    size_t count;
} zat_car_records;

/*
 * com.atproto.repo.getRecord. `at_uri` must be a full at:// URI including
 * collection and rkey. On success *out holds the JSON response body
 * ({"uri", "cid", "value"}); release with zat_string_deinit.
 */
zat_status zat_get_record_json(zat_explorer *explorer, const char *at_uri,
                               zat_string *out, zat_error_details *details);

/*
 * com.atproto.repo.listRecords. `limit == 0` means "server default".
 * `cursor` may be NULL on the first call; pass the "cursor" field of the
 * previous response to page forward. On success *out holds the raw JSON
 * response body ({"records": [...], "cursor": "..."}); release with
 * zat_string_deinit.
 */
zat_status zat_list_records_json(zat_explorer *explorer, const char *repo,
                                 const char *collection, uint32_t limit,
                                 const char *cursor, zat_string *out,
                                 zat_error_details *details);

/*
 * com.atproto.repo.describeRepo. On success *out holds the JSON response
 * body ({"did", "collections", ...}); release with zat_string_deinit.
 */
zat_status zat_describe_repo_json(zat_explorer *explorer, const char *repo,
                                  zat_string *out, zat_error_details *details);

/*
 * com.atproto.sync.getRepo — the repo's full CAR (every record + MST).
 * On success *out holds raw CAR bytes; release with zat_blob_deinit.
 * Binary payload; NOT NUL-terminated.
 */
zat_status zat_fetch_repo_car(zat_explorer *explorer, const char *did,
                              zat_blob *out, zat_error_details *details);

/*
 * Decode every record of a full repo CAR (commit block + MST walk + record
 * blocks, all DAG-CBOR) into an owned listing. `car_bytes`/`car_len` are the
 * raw CAR bytes, e.g. from zat_fetch_repo_car; they are copied, so the
 * caller may free them immediately. Each record carries its path
 * ("collection/rkey"), multibase CID, and the record body as JSON. On
 * success *out is set and must be released with zat_car_records_deinit.
 */
zat_status zat_iterate_car_records(const uint8_t *car_bytes, size_t car_len,
                                   zat_car_records **out);

/* Free + zero a zat_car_records returned by zat_iterate_car_records. */
void zat_car_records_deinit(zat_car_records *records);

/*
 * Deterministic testing: a scripted transport serves an explorer's XRPC
 * traffic without a network. Responses are consumed in FIFO order; requests
 * are recorded for assertions (count, last URL). A 429 queued with
 * retry_after_seconds = 0 exercises the retry path instantly (no sleeping).
 *
 * OWNERSHIP: the fake is independent of the sessions it feeds. Create it,
 * pass it to zat_explorer_create_with_fake, and destroy it AFTER every
 * explorer that uses it. Last url is released with zat_string_deinit.
 */
typedef struct zat_fake_transport zat_fake_transport;

zat_status zat_fake_transport_create(zat_fake_transport **out);
void zat_fake_transport_destroy(zat_fake_transport *fake);

/* Queue the next response. `status` is an HTTP code (200/201/204/400/401/
 * 403/404/409/429/500/502/503/504); `retry_after_seconds < 0` means no
 * retry-after header. `body` is copied. */
zat_status zat_fake_transport_queue_response(zat_fake_transport *fake,
                                             int status, const char *body,
                                             int retry_after_seconds);

/* Number of requests served so far. */
size_t zat_fake_transport_request_count(zat_fake_transport *fake);

/* URL of the most recent request; ZAT_ERROR_INVALID_ARGUMENT when none. */
zat_status zat_fake_transport_last_url(zat_fake_transport *fake, zat_string *out);

/* Create an explorer whose XRPC traffic is served by `fake` instead of the
 * network (identity resolution still uses the network: it does its own DNS/
 * PLC lookups outside the transport seam). */
zat_status zat_explorer_create_with_fake(const char *host,
                                         zat_fake_transport *fake,
                                         zat_explorer **out);

#ifdef __cplusplus
}
#endif

#endif /* ZAT_H */

/*
 * Swift quick start (link libzat_c.a, add this header to the target):
 *
 *   var explorer: UnsafeMutablePointer<zat_explorer>?
 *   zat_explorer_create("https://bsky.social", &explorer)
 *   defer { zat_explorer_destroy(explorer!) }
 *
 *   var identity = zat_identity()
 *   zat_resolve_identity(explorer, "atproto.com", &identity)
 *   defer { zat_identity_deinit(&identity) }
 *   let did = String(cString: identity.did.ptr!)
 *   let pds = identity.pds.ptr.map { String(cString: $0) }   // optional
 *
 *   var page = zat_string()
 *   var details = zat_error_details()
 *   zat_list_records_json(explorer, did, "app.bsky.feed.post", 25, nil, &page, &details)
 *   defer { zat_string_deinit(&page) }
 *   if (details.http_status != 0) {
 *       // non-2xx: details.error_name / details.message / details.retry_after
 *       defer { zat_error_details_deinit(&details) }
 *   }
 *   let json = String(decoding: Data(bytes: page.ptr!, count: page.len), as: UTF8.self)
 */
