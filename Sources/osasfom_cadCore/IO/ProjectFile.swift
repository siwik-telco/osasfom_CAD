import Foundation

/// The on-disk project format.
///
/// Deliberately distinct from the solver export: this file is the *editable
/// source*, so it stores expressions verbatim and never resolved numbers. The
/// solver export is a separate, fully resolved SI document
/// (`SolverExportEncoder`). Conflating the two is why the old export was a dead
/// end — it could not be read back.
public struct CADProjectFile: Codable, Sendable {
    /// 1 — the original prototype (body-only, `PrimitiveParameters`, name-based
    ///     variable bindings). Read-only, via `LegacyProjectImporter`.
    /// 2 — expressions, simulation setup, priorities, FDTD materials.
    public static let currentFormatVersion = 2

    public var formatVersion: Int
    public var generator: String
    public var state: CADModelState

    public init(state: CADModelState, generator: String = CADProjectFile.defaultGenerator) {
        self.formatVersion = Self.currentFormatVersion
        self.generator = generator
        self.state = state
    }

    public static let defaultGenerator = "osasfom_cad"
}

public enum ProjectFileError: Error, LocalizedError {
    case unreadable(underlying: Error)
    case unsupportedVersion(found: Int, supported: Int)
    case notAProjectFile

    public var errorDescription: String? {
        switch self {
        case .unreadable(let underlying):
            return "The project file could not be read: \(underlying.localizedDescription)"
        case .unsupportedVersion(let found, let supported):
            return "This project was written by a newer version of osasfom_cad (format \(found); this build understands up to \(supported))."
        case .notAProjectFile:
            return "That file is not an osasfom_cad project."
        }
    }
}

public enum ProjectSerializer {
    public static func encode(_ state: CADModelState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(CADProjectFile(state: state))
    }

    /// Reads a project file, transparently upgrading a v1 prototype file.
    public static func decode(_ data: Data) throws -> CADModelState {
        let decoder = JSONDecoder()

        // Peek at the version before committing to a shape.
        struct VersionProbe: Decodable {
            let formatVersion: Int?
        }

        let probedVersion: Int?
        do {
            probedVersion = try decoder.decode(VersionProbe.self, from: data).formatVersion
        } catch {
            throw ProjectFileError.notAProjectFile
        }

        switch probedVersion {
        case .none:
            // No version field: the original prototype's bare `CADProject`.
            return try LegacyProjectImporter.importVersion1(data)
        case .some(let version) where version <= CADProjectFile.currentFormatVersion:
            if version < CADProjectFile.currentFormatVersion {
                return try LegacyProjectImporter.importVersion1(data)
            }
            do {
                return try decoder.decode(CADProjectFile.self, from: data).state
            } catch {
                throw ProjectFileError.unreadable(underlying: error)
            }
        case .some(let version):
            throw ProjectFileError.unsupportedVersion(
                found: version,
                supported: CADProjectFile.currentFormatVersion
            )
        }
    }

    public static func write(_ state: CADModelState, to url: URL) throws {
        try encode(state).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> CADModelState {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProjectFileError.unreadable(underlying: error)
        }
        return try decode(data)
    }
}
