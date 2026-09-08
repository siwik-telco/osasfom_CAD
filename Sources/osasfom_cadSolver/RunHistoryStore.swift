import Foundation
import osasfom_cadCore

/// Keeps a project's run history on disk between sessions.
///
/// History lives outside the project file on purpose: results are derived
/// data, often tens of megabytes across a working session, and a `.osasfomcad`
/// file is the editable *source*. Losing history should never risk the model.
public final class RunHistoryStore {

    /// Older runs are dropped once this many are stored. A far-field pattern
    /// is a few tens of kilobytes, so this bounds a project's history at a
    /// few megabytes rather than letting it grow without limit.
    public static let defaultLimit = 50

    private let directory: URL
    private let limit: Int
    private let fileManager: FileManager

    /// `directory` defaults to Application Support, and is injectable so a
    /// test never writes into the user's real history.
    public init(
        directory: URL? = nil,
        limit: Int = RunHistoryStore.defaultLimit,
        fileManager: FileManager = .default
    ) {
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
        self.limit = max(1, limit)
        self.fileManager = fileManager
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("osasfom_cad", isDirectory: true)
            .appendingPathComponent("RunHistory", isDirectory: true)
    }

    // MARK: - Identity

    /// One history file per project.
    ///
    /// The name carries the project's own name so the folder is legible, plus
    /// a hash of its full path so two projects called `patch` in different
    /// folders don't share — or overwrite — each other's runs.
    func fileURL(for project: URL?) -> URL {
        guard let project else {
            return directory.appendingPathComponent("untitled.json")
        }
        let standardized = project.standardizedFileURL
        let name = standardized.deletingPathExtension().lastPathComponent
        let safeName = name.isEmpty ? "project" : name.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safeName)-\(Self.digest(standardized.path)).json")
    }

    /// A short, stable, non-cryptographic digest of the path. Only needs to
    /// separate projects, not resist anything.
    private static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    // MARK: - Reading and writing

    /// Returns an empty history rather than throwing: a missing or unreadable
    /// history file must never stop a project from opening.
    public func load(project: URL?) -> [RunRecord] {
        guard let data = try? Data(contentsOf: fileURL(for: project)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([RunRecord].self, from: data) else { return [] }
        return records
    }

    @discardableResult
    public func save(_ records: [RunRecord], project: URL?) -> Bool {
        let trimmed = Array(records.suffix(limit))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(trimmed).write(to: fileURL(for: project), options: .atomic)
            return true
        } catch {
            // Failing to persist history is not worth interrupting a run over.
            return false
        }
    }

    public func clear(project: URL?) {
        try? fileManager.removeItem(at: fileURL(for: project))
    }
}
