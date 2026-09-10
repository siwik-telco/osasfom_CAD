import Foundation

/// Reads an STL mesh so it can be brought in as a body — the counterpart to
/// `STLExporter`.
///
/// Both STL flavours are accepted. The format is not self-describing: a binary
/// file's 80-byte header is free-form and an ASCII file merely *tends* to
/// start with "solid", which some binary writers also do. So the flavour is
/// decided by arithmetic — the declared triangle count of a binary file
/// predicts its exact length — rather than by the header text, which is the
/// classic way STL readers get this wrong.
///
/// STL carries no units. `unit` says what the file's numbers mean, and the
/// triangles come back converted into the project's own unit.
public enum STLImporter {

    public struct Result {
        /// Triangles in the body's local frame: recentred on the mesh's
        /// bounding-box centre, matching the convention every other primitive
        /// uses (`STLExporter.localTriangles`).
        public let mesh: TriangleMesh
        /// Where the mesh sat in the file's own coordinates. Handed to the
        /// body's position so the model lands where the file put it.
        public let origin: Vec3
        /// Size of the mesh in project units, for the import summary.
        public var size: Vec3 { mesh.bounds.size }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case empty
        case truncated
        case malformedASCII(line: Int)
        case tooManyTriangles(found: Int, limit: Int)

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "That STL file contains no triangles."
            case .truncated:
                return "That STL file ends mid-triangle — it looks truncated or corrupt."
            case .malformedASCII(let line):
                return "That STL file could not be parsed (line \(line))."
            case .tooManyTriangles(let found, let limit):
                return """
                That STL has \(found) triangles, past this build's limit of \(limit). \
                Point-in-solid is sampled millions of times per FDTD run, so a mesh this \
                dense would dominate the solve. Decimate it in your CAD tool first.
                """
            }
        }
    }

    /// Meshes above this are refused rather than accepted and then blamed for
    /// a slow solve. The BVH keeps a query logarithmic, but building it, the
    /// project file it has to fit in, and the renderer all scale linearly.
    public static let triangleLimit = 2_000_000

    /// Parses `data` and converts it from `unit` into `projectUnit`.
    public static func load(
        _ data: Data,
        unit: LengthUnit,
        projectUnit: LengthUnit
    ) throws -> Result {
        let raw = isBinary(data) ? try decodeBinary(data) : try decodeASCII(data)
        guard !raw.isEmpty else { throw Failure.empty }
        guard raw.count <= triangleLimit else {
            throw Failure.tooManyTriangles(found: raw.count, limit: triangleLimit)
        }

        let scale = unit.metersPerUnit / projectUnit.metersPerUnit
        let scaled = scale == 1 ? raw : raw.map { triangle in
            STLExporter.Triangle(
                v0: triangle.v0 * scale,
                v1: triangle.v1 * scale,
                v2: triangle.v2 * scale
            )
        }

        guard let bounds = BodyBounds.enclosing(points: scaled.flatMap { [$0.v0, $0.v1, $0.v2] }) else {
            throw Failure.empty
        }
        let origin = bounds.center
        let centred = scaled.map { triangle in
            STLExporter.Triangle(
                v0: triangle.v0 - origin,
                v1: triangle.v1 - origin,
                v2: triangle.v2 - origin
            )
        }

        guard let mesh = TriangleMesh(triangles: centred) else { throw Failure.empty }
        return Result(mesh: mesh, origin: origin)
    }

    // MARK: - Flavour detection

    /// A binary STL is exactly `80 + 4 + 50 * count` bytes long. Reading the
    /// count and checking the length is decisive; the header text is not.
    static func isBinary(_ data: Data) -> Bool {
        guard data.count >= 84 else { return false }
        let count = readUInt32LE(data, at: 80)
        guard count <= UInt32(triangleLimit) else { return false }
        return data.count == 84 + Int(count) * 50
    }

    // MARK: - Binary

    private static func decodeBinary(_ data: Data) throws -> [STLExporter.Triangle] {
        let count = Int(readUInt32LE(data, at: 80))
        guard data.count >= 84 + count * 50 else { throw Failure.truncated }

        var triangles: [STLExporter.Triangle] = []
        triangles.reserveCapacity(count)
        for index in 0..<count {
            // 50 bytes: 3 floats of normal (recomputed on use, so skipped),
            // 9 floats of vertices, 2 bytes of attribute count.
            let base = 84 + index * 50 + 12
            func vertex(_ offset: Int) -> Vec3 {
                Vec3(
                    x: Double(readFloatLE(data, at: base + offset)),
                    y: Double(readFloatLE(data, at: base + offset + 4)),
                    z: Double(readFloatLE(data, at: base + offset + 8))
                )
            }
            triangles.append(STLExporter.Triangle(v0: vertex(0), v1: vertex(12), v2: vertex(24)))
        }
        return triangles
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16
            | UInt32(data[base + 3]) << 24
    }

    private static func readFloatLE(_ data: Data, at offset: Int) -> Float32 {
        Float32(bitPattern: readUInt32LE(data, at: offset))
    }

    // MARK: - ASCII

    /// Reads `vertex x y z` triples and groups them in threes.
    ///
    /// Tolerant on purpose: `facet normal`, `outer loop`, `endloop`,
    /// `endfacet`, `solid` and `endsolid` carry nothing this importer needs
    /// (the normal is recomputed from winding), so they are skipped rather
    /// than validated. Real files in the wild vary in whitespace and in which
    /// of those they bother to write.
    private static func decodeASCII(_ data: Data) throws -> [STLExporter.Triangle] {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw Failure.malformedASCII(line: 0)
        }

        var vertices: [Vec3] = []
        var lineNumber = 0

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let keyword = fields.first, keyword == "vertex" else { continue }
            guard fields.count >= 4,
                  let x = Double(fields[1]),
                  let y = Double(fields[2]),
                  let z = Double(fields[3]) else {
                throw Failure.malformedASCII(line: lineNumber)
            }
            vertices.append(Vec3(x: x, y: y, z: z))
        }

        guard vertices.count % 3 == 0 else { throw Failure.truncated }
        return stride(from: 0, to: vertices.count, by: 3).map { index in
            STLExporter.Triangle(v0: vertices[index], v1: vertices[index + 1], v2: vertices[index + 2])
        }
    }
}
