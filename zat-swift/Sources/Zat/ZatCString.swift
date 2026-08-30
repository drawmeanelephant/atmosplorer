import Czat
import Foundation

/// Copies a `zat_string` into a Swift String without freeing it — for fields
/// owned by a parent struct (e.g. `zat_identity`), which the parent's deinit
/// frees.
func readZatString(_ value: zat_string) -> String? {
    guard let ptr = value.ptr else { return nil }
    let bytes = UnsafeBufferPointer(
        start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self),
        count: Int(value.len)
    )
    return String(decoding: bytes, as: UTF8.self)
}

/// Consumes a `zat_string` returned by the ABI, freeing its memory.
func takeZatString(_ value: inout zat_string) -> String? {
    defer { zat_string_deinit(&value) }
    return readZatString(value)
}

/// Consumes a `zat_blob` returned by the ABI, freeing its memory.
func takeZatBlob(_ value: inout zat_blob) -> Data? {
    defer { zat_blob_deinit(&value) }
    guard let ptr = value.ptr else { return nil }
    return Data(bytes: ptr, count: Int(value.len))
}

/// Consumes a `zat_error_details` returned by a failed network call, freeing
/// its memory. Returns nil when the struct carries no envelope
/// (`http_status == 0`, e.g. validation failures that never reached the
/// network).
func takeZatErrorDetails(_ value: inout zat_error_details) -> ZatErrorDetails? {
    defer { zat_error_details_deinit(&value) }
    guard value.http_status != 0 else { return nil }
    return ZatErrorDetails(value)
}
