import Czat
import XCTest

@testable import Zat

final class ZatErrorTests: XCTestCase {
    func testMapsStatusCodes() {
        XCTAssertEqual(ZatError(zat_status(rawValue: 1)), .invalidArgument)
        XCTAssertEqual(ZatError(zat_status(rawValue: 2)), .invalidIdentifier)
        XCTAssertEqual(ZatError(zat_status(rawValue: 3)), .invalidResponse)
        XCTAssertEqual(ZatError(zat_status(rawValue: 4)), .missingField)
        XCTAssertEqual(ZatError(zat_status(rawValue: 5)), .missingPds)
        XCTAssertEqual(ZatError(zat_status(rawValue: 6)), .network)
        XCTAssertEqual(ZatError(zat_status(rawValue: 7)), .outOfMemory)
        XCTAssertEqual(ZatError(zat_status(rawValue: 8)), .unexpected)
    }

    func testCheckThrowsOnFailureAndPassesOnSuccess() {
        XCTAssertNoThrow(try ZatError.check(zat_status(rawValue: 0)))
        XCTAssertThrowsError(try ZatError.check(zat_status(rawValue: 6))) { error in
            XCTAssertEqual(error as? ZatError, .network)
        }
    }

    /// Everything below hits the ABI's validate-before-network contract, so
    /// these run offline and deterministically.
    func testRejectsEmptyHost() {
        XCTAssertThrowsError(try ZatExplorer(host: "")) { error in
            XCTAssertEqual(error as? ZatError, .invalidArgument)
        }
    }

    func testRejectsMalformedIdentifiersBeforeNetwork() throws {
        let explorer = try ZatExplorer(host: "https://example.invalid")
        XCTAssertThrowsError(try explorer.resolveIdentity("not an identifier")) { error in
            XCTAssertEqual(error as? ZatError, .invalidIdentifier)
        }
        XCTAssertThrowsError(try explorer.getRecord(at: "not an at-uri", as: ZatJSONValue.self)) { error in
            XCTAssertEqual(error as? ZatError, .invalidIdentifier)
        }
        XCTAssertThrowsError(
            try explorer.listRecords(repo: "nope", collection: "app.bsky.feed.post", as: ZatJSONValue.self)
        ) { error in
            XCTAssertEqual(error as? ZatError, .invalidIdentifier)
        }
        XCTAssertThrowsError(
            try explorer.listRecords(repo: "did:plc:abc", collection: "not-an-nsid", as: ZatJSONValue.self)
        ) { error in
            XCTAssertEqual(error as? ZatError, .invalidIdentifier)
        }
        XCTAssertThrowsError(try explorer.describeRepo("nope")) { error in
            XCTAssertEqual(error as? ZatError, .invalidIdentifier)
        }
        XCTAssertThrowsError(try explorer.fetchRepoCar(did: "not-a-did")) { error in
            XCTAssertEqual(error as? ZatError, .invalidIdentifier)
        }
    }

    func testDataSessionRequiresPds() throws {
        let explorer = try ZatExplorer(host: "https://example.invalid")
        let identity = ZatIdentity(did: "did:plc:abc", handle: nil, pds: nil)
        XCTAssertThrowsError(try explorer.dataSession(for: identity)) { error in
            XCTAssertEqual(error as? ZatError, .missingPds)
        }
    }

    func testCoreVersionIsPresent() {
        XCTAssertFalse(ZatExplorer.coreVersion.isEmpty)
    }
}
