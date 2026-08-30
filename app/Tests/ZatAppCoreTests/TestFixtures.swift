import Foundation

/// Shared test fixtures for the offline suite.
enum TestFixtures {
    /// Deterministic output of the zat core's `zig build gen-car-fixture`
    /// (a 2-record `app.bsky.feed.post` repo), base64-encoded. Regenerate
    /// with:
    ///
    ///     (cd DEVKITS/zat-main && zig build gen-car-fixture | base64 | tr -d '\n')
    static let carBase64 =
        "OqJlcm9vdHOB2CpYJQABcRIg8whTzJcN1ei6RLX07hC14U7XFzMFxYVmxXTTRl90411ndmVyc2lvbgGNAQFxEiDzCFPMlw3V6LpEtfTuELXhTtcXMwXFhWbFdNNGX3TjXaVjZGlkb2RpZDpwbGM6dGVzdDEyM2NyZXZsM2syYWJjMDAwMDAwY3NpZ0dmYWtlc2lnZGRhdGHYKlglAAFxEiCMNa73ajUWU7QTJmr+BeTM/062QMAWEcJtBImnf/0b82d2ZXJzaW9uA0kBcRIgS+2EbICFfTWwoYB9wcWn6g3+MWYzCw/jghmb4KSr1MiiZHRleHRlaGVsbG9lJHR5cGVyYXBwLmJza3kuZmVlZC5wb3N0SQFxEiABiUX+4QelZaHiXXoGb2MRTeF+odjX/bTUiC1J2zyL9aJkdGV4dGV3b3JsZGUkdHlwZXJhcHAuYnNreS5mZWVkLnBvc3StAQFxEiCMNa73ajUWU7QTJmr+BeTM/062QMAWEcJtBImnf/0b86JhZYKkYWtXYXBwLmJza3kuZmVlZC5wb3N0LzNqejFhcABhdPZhdtgqWCUAAXESIEvthGyAhX01sKGAfcHFp+oN/jFmMwsP44IZm+Ckq9TIpGFrQTJhcBZhdPZhdtgqWCUAAXESIAGJRf7hB6VloeJdegZvYxFN4X6h2Nf9tNSILUnbPIv1YWz2"

    /// Decode the fixture; nil when the constant is malformed.
    static func carData() -> Data? {
        Data(base64Encoded: carBase64)
    }
}
