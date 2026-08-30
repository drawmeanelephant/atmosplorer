//! c_root.zig — the C ABI root module of the `zat_c` static library.
//!
//! OUR CODE. The overlay build.zig wires this as the root module of the
//! `zat_c` static library with the import `{ .name = "zat", .module = <zat> }`
//! and `link_libc`. All the marshalling lives in c_api.zig; this file simply
//! re-exports every symbol in include/zat.h under its C name so the Swift
//! wrapper (which links against libzat_c.a and reads zat.h) finds them.

const c_api = @import("c_api.zig");

comptime {
    @export(&c_api.zat_version, .{ .name = "zat_version" });
    @export(&c_api.zat_free, .{ .name = "zat_free" });

    @export(&c_api.zat_explorer_create, .{ .name = "zat_explorer_create" });
    @export(&c_api.zat_explorer_destroy, .{ .name = "zat_explorer_destroy" });
    @export(&c_api.zat_explorer_create_with_fake, .{ .name = "zat_explorer_create_with_fake" });

    @export(&c_api.zat_resolve_identity, .{ .name = "zat_resolve_identity" });
    @export(&c_api.zat_identity_deinit, .{ .name = "zat_identity_deinit" });

    @export(&c_api.zat_string_deinit, .{ .name = "zat_string_deinit" });
    @export(&c_api.zat_blob_deinit, .{ .name = "zat_blob_deinit" });
    @export(&c_api.zat_error_details_deinit, .{ .name = "zat_error_details_deinit" });

    @export(&c_api.zat_get_record_json, .{ .name = "zat_get_record_json" });
    @export(&c_api.zat_list_records_json, .{ .name = "zat_list_records_json" });
    @export(&c_api.zat_describe_repo_json, .{ .name = "zat_describe_repo_json" });
    @export(&c_api.zat_fetch_repo_car, .{ .name = "zat_fetch_repo_car" });

    @export(&c_api.zat_iterate_car_records, .{ .name = "zat_iterate_car_records" });
    @export(&c_api.zat_car_records_deinit, .{ .name = "zat_car_records_deinit" });

    @export(&c_api.zat_fake_transport_create, .{ .name = "zat_fake_transport_create" });
    @export(&c_api.zat_fake_transport_destroy, .{ .name = "zat_fake_transport_destroy" });
    @export(&c_api.zat_fake_transport_queue_response, .{ .name = "zat_fake_transport_queue_response" });
    @export(&c_api.zat_fake_transport_request_count, .{ .name = "zat_fake_transport_request_count" });
    @export(&c_api.zat_fake_transport_last_url, .{ .name = "zat_fake_transport_last_url" });
}