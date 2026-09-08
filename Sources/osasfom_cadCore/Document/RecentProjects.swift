import Foundation

/// The list of projects the user has opened or saved, most recent first.
///
/// Lives in Core rather than the app so the ordering, de-duplication and
/// pruning rules are unit-testable; it is Foundation-only, and the store it
/// writes to is injectable precisely so a test never touches the real
/// preferences.
public final class RecentProjects: ObservableObject {

    public struct Entry: Identifiable, Hashable, Sendable {
        public let url: URL
        public let lastOpened: Date

        public var id: URL { url }

        /// File name without the `.osasfomcad` extension.
        public var name: String { url.deletingPathExtension().lastPathComponent }

        /// Containing folder, with the home directory abbreviated — the part
        /// that tells two same-named projects apart.
        public var location: String {
            (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        }

        /// False once the file has been moved, renamed or deleted behind the
        /// app's back. Kept in the list rather than dropped silently, so the
        /// row can say what happened instead of the entry just vanishing.
        public var stillExists: Bool {
            FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// Ten or so is the useful range: enough to cover a working session's
    /// worth of projects, short enough to stay scannable without a scroll.
    public static let defaultLimit = 10

    @Published public private(set) var entries: [Entry] = []

    private let defaults: UserDefaults
    private let key: String
    private let limit: Int

    public init(
        defaults: UserDefaults = .standard,
        key: String = "osasfom_cad.recentProjects",
        limit: Int = RecentProjects.defaultLimit
    ) {
        self.defaults = defaults
        self.key = key
        self.limit = max(1, limit)
        self.entries = Self.decode(defaults.array(forKey: key))
    }

    /// Moves `url` to the front, or adds it. Recording the same project twice
    /// must not produce two rows, so entries are keyed by their resolved
    /// path — `/tmp/a.osasfomcad` and `/tmp/./a.osasfomcad` are one project.
    public func record(_ url: URL) {
        let standardized = url.standardizedFileURL
        var updated = entries.filter { $0.url != standardized }
        updated.insert(Entry(url: standardized, lastOpened: Date()), at: 0)
        commit(Array(updated.prefix(limit)))
    }

    public func remove(_ url: URL) {
        commit(entries.filter { $0.url != url.standardizedFileURL })
    }

    /// Drops every entry whose file is gone — the "clean up the list" action,
    /// kept explicit rather than happening silently on load, so a project on
    /// an unmounted volume isn't forgotten just because it wasn't plugged in.
    public func removeMissing() {
        commit(entries.filter(\.stillExists))
    }

    public func clear() {
        commit([])
    }

    private func commit(_ newEntries: [Entry]) {
        entries = newEntries
        defaults.set(Self.encode(newEntries), forKey: key)
    }

    // MARK: - Storage

    private enum StorageKey {
        static let path = "path"
        static let opened = "opened"
    }

    private static func encode(_ entries: [Entry]) -> [[String: Any]] {
        entries.map { entry in
            [
                StorageKey.path: entry.url.path,
                StorageKey.opened: entry.lastOpened.timeIntervalSinceReferenceDate
            ]
        }
    }

    /// Anything unreadable is skipped rather than throwing: a corrupt
    /// preference should cost the user their recent list, not their launch.
    private static func decode(_ raw: [Any]?) -> [Entry] {
        guard let raw else { return [] }
        return raw.compactMap { element in
            guard
                let dictionary = element as? [String: Any],
                let path = dictionary[StorageKey.path] as? String,
                !path.isEmpty
            else { return nil }
            let interval = dictionary[StorageKey.opened] as? TimeInterval ?? 0
            return Entry(
                url: URL(fileURLWithPath: path).standardizedFileURL,
                lastOpened: Date(timeIntervalSinceReferenceDate: interval)
            )
        }
    }
}
