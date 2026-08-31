import XCTest
import Zat
@testable import Atmosplorer
@testable import ZatAppCore

/// Offline tests for the app-side `FavoritesModel`: the toggle/contains state
/// the star button drives, the detail-column selection, and the at:// repo
/// parsing. Backed by a throwaway `FavoritesStore` directory — no network.
@MainActor
final class FavoritesModelTests: XCTestCase {
    private var directory: URL!
    private var model: FavoritesModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atmosplorer-favmodel-tests-\(UUID().uuidString)", isDirectory: true)
        model = FavoritesModel(store: FavoritesStore(directory: directory))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func selection(uri: String, text: String) -> RecordSelection {
        RecordSelection(uri: uri, cid: "cid-\(text)", value: ["text": .string(text)])
    }

    func testToggleFlipsStarState() {
        let record = selection(uri: "at://did:plc:repo1/app.bsky.feed.post/1", text: "hi")

        XCTAssertFalse(model.contains(record.uri))
        XCTAssertTrue(model.toggle(record))
        XCTAssertTrue(model.contains(record.uri))
        XCTAssertFalse(model.toggle(record))
        XCTAssertFalse(model.contains(record.uri))
    }

    /// Toggling on stores the record's full decoded value so the Favorites
    /// list can render and open it offline.
    func testToggleStoresValueAndRepo() {
        let record = selection(uri: "at://did:plc:repo1/app.bsky.feed.post/1", text: "hello")

        _ = model.toggle(record)
        let favorite = model.favorites.first
        XCTAssertEqual(favorite?.value["text"]?.stringValue, "hello")
        XCTAssertEqual(favorite?.repoDid, "did:plc:repo1")
        XCTAssertEqual(favorite?.repoName, "did:plc:repo1")
    }

    /// Unstarring the favorite currently open in the detail column closes it
    /// instead of leaving a stale view on screen.
    func testUnfavoriteSelectedClosesDetail() {
        let record = selection(uri: "at://did:plc:repo1/app.bsky.feed.post/1", text: "hi")
        _ = model.toggle(record)
        model.selectedURI = record.uri

        _ = model.toggle(record)

        XCTAssertFalse(model.contains(record.uri))
        XCTAssertNil(model.selectedURI)
    }

    /// Unstarring a favorite that isn't the one on screen keeps the current
    /// detail selection untouched.
    func testUnfavoriteNonSelectedKeepsDetail() {
        let open = selection(uri: "at://did:plc:repo1/app.bsky.feed.post/open", text: "open")
        let other = selection(uri: "at://did:plc:repo1/app.bsky.feed.post/other", text: "other")
        _ = model.toggle(open)
        _ = model.toggle(other)
        model.selectedURI = open.uri

        _ = model.toggle(other)

        XCTAssertEqual(model.selectedURI, open.uri)
    }

    func testRemoveClearsSelection() {
        let record = selection(uri: "at://did:plc:repo1/app.bsky.feed.post/1", text: "hi")
        _ = model.toggle(record)
        model.selectedURI = record.uri

        model.remove(uri: record.uri)

        XCTAssertNil(model.selectedURI)
        XCTAssertTrue(model.favorites.isEmpty)
    }

    func testRepoParsingFromURI() {
        XCTAssertEqual(
            FavoritesModel.repoDid(from: "at://did:plc:abc/app.bsky.feed.post/rk"),
            "did:plc:abc")
        XCTAssertEqual(
            FavoritesModel.repoDid(from: "at://alice.test/app.bsky.feed.post/rk"),
            "alice.test")
        // Malformed URIs degrade to nil; the model falls back to the URI.
        XCTAssertNil(FavoritesModel.repoDid(from: "not-an-at-uri"))
        XCTAssertNil(FavoritesModel.repoDid(from: "at://only-two-parts"))
    }
}
