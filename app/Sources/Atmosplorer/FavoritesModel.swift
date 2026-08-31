import Foundation
import ZatAppCore

/// App-wide favorites: the `FavoritesStore` on disk plus the sidebar list and
/// the detail-column selection. The decoded record value is stored with each
/// favorite, so opening one from the list is fully offline — the repo's CAR
/// needn't even be cached anymore.
@MainActor
final class FavoritesModel: ObservableObject {
    /// All saved favorites, newest first (drives the sidebar section).
    @Published private(set) var favorites: [FavoriteRecord] = []
    /// The favorite currently open in the detail column (its URI); nil when a
    /// cached repo or live preview is shown instead.
    @Published var selectedURI: String?

    let store: FavoritesStore

    init(store: FavoritesStore? = nil) {
        self.store = store ?? FavoritesStore()
        refresh()
    }

    func contains(_ uri: String) -> Bool {
        favorites.contains { $0.uri == uri }
    }

    /// Toggle the star on `selection`. The repo is parsed out of the at://
    /// URI (`at://<did>/<nsid>/<rkey>`); `repoName` is display sugar when
    /// known, else the DID. Unstarring the favorite currently open in the
    /// detail column closes it rather than leaving a stale view. Returns
    /// whether the record is now bookmarked.
    @discardableResult
    func toggle(_ selection: RecordSelection, repoName: String? = nil) -> Bool {
        let repoDid = Self.repoDid(from: selection.uri) ?? selection.uri
        let name = repoName ?? repoDid
        do {
            let nowFavorite = try store.toggle(
                uri: selection.uri, cid: selection.cid, value: selection.value,
                repoDid: repoDid, repoName: name)
            refresh()
            if !nowFavorite && selectedURI == selection.uri {
                selectedURI = nil
            }
            return nowFavorite
        } catch {
            // A failed write leaves the on-disk state unchanged; the star
            // reflects what's actually stored, never a hopeful guess.
            return contains(selection.uri)
        }
    }

    func remove(uri: String) {
        try? store.remove(uri: uri)
        if selectedURI == uri { selectedURI = nil }
        refresh()
    }

    func refresh() {
        favorites = store.favorites()
    }

    /// The repo part of an at:// URI (`at://<repo>/<nsid>/<rkey>`), when the
    /// URI is well-formed. Pure string parsing, so it is `nonisolated`.
    nonisolated static func repoDid(from uri: String) -> String? {
        let parts = uri.split(separator: "/")
        guard uri.hasPrefix("at://"), parts.count >= 3 else { return nil }
        return String(parts[1])
    }
}
