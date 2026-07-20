import Foundation

public struct Vec3: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(x: 0, y: 0, z: 0)
    public static let one = Vec3(x: 1, y: 1, z: 1)
}

public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let neutralGray = RGBAColor(red: 0.72, green: 0.74, blue: 0.78)
}

public struct MaterialDefinition: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var color: RGBAColor
    public var epsilonR: Double?
    public var conductivity: Double?

    public init(
        id: UUID = UUID(),
        name: String,
        color: RGBAColor,
        epsilonR: Double? = nil,
        conductivity: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.epsilonR = epsilonR
        self.conductivity = conductivity
    }
}

public enum PrimitiveKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case box
    case cylinder
    case sheet

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .box:
            return "Box"
        case .cylinder:
            return "Cylinder"
        case .sheet:
            return "Sheet"
        }
    }
}

public struct PrimitiveParameters: Codable, Hashable, Sendable {
    public var size: Vec3
    public var radius: Double
    public var height: Double

    public init(size: Vec3, radius: Double, height: Double) {
        self.size = size
        self.radius = radius
        self.height = height
    }

    public mutating func sanitize(for kind: PrimitiveKind) {
        size.x = max(size.x, 0.01)
        size.y = max(size.y, 0.01)
        size.z = max(size.z, 0.01)
        radius = max(radius, 0.01)
        height = max(height, 0.01)

        switch kind {
        case .box:
            break
        case .cylinder:
            size = Vec3(x: max(size.x, 0.01), y: max(size.y, 0.01), z: max(size.z, 0.01))
        case .sheet:
            size.y = max(size.y, 0.01)
        }
    }

    public static let defaultBox = PrimitiveParameters(
        size: Vec3(x: 40, y: 10, z: 30),
        radius: 5,
        height: 20
    )

    public static let defaultCylinder = PrimitiveParameters(
        size: Vec3(x: 10, y: 10, z: 10),
        radius: 2.5,
        height: 30
    )

    public static let defaultSheet = PrimitiveParameters(
        size: Vec3(x: 60, y: 0.2, z: 40),
        radius: 1,
        height: 0.2
    )
}

public struct BodyTransform: Codable, Hashable, Sendable {
    public var position: Vec3
    public var rotationDegrees: Vec3
    public var scale: Vec3

    public init(
        position: Vec3 = .zero,
        rotationDegrees: Vec3 = .zero,
        scale: Vec3 = .one
    ) {
        self.position = position
        self.rotationDegrees = rotationDegrees
        self.scale = scale
    }
}

public struct CADBody: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var primitive: PrimitiveKind
    public var parameters: PrimitiveParameters
    public var transform: BodyTransform
    public var materialID: UUID?
    public var isVisible: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        primitive: PrimitiveKind,
        parameters: PrimitiveParameters,
        transform: BodyTransform = BodyTransform(),
        materialID: UUID? = nil,
        isVisible: Bool = true
    ) {
        self.id = id
        self.name = name
        self.primitive = primitive
        self.parameters = parameters
        self.transform = transform
        self.materialID = materialID
        self.isVisible = isVisible
    }

    public static func make(kind: PrimitiveKind, index: Int) -> CADBody {
        switch kind {
        case .box:
            return CADBody(
                name: "Box \(index)",
                primitive: .box,
                parameters: .defaultBox
            )
        case .cylinder:
            return CADBody(
                name: "Cylinder \(index)",
                primitive: .cylinder,
                parameters: .defaultCylinder
            )
        case .sheet:
            return CADBody(
                name: "Sheet \(index)",
                primitive: .sheet,
                parameters: .defaultSheet
            )
        }
    }
}

public struct CADProject: Codable, Sendable {
    public var units: String
    public var bodies: [CADBody]
    public var materials: [MaterialDefinition]

    public init(units: String = "mm", bodies: [CADBody], materials: [MaterialDefinition]) {
        self.units = units
        self.bodies = bodies
        self.materials = materials
    }
}

public enum MaterialLibrary {
    public static let copperID = UUID(uuidString: "9F848155-FB5D-4D34-B7AF-689A43CBEA01")!
    public static let aluminumID = UUID(uuidString: "3AD78F26-F2F1-489A-B145-09C7B0D8DCC2")!
    public static let fr4ID = UUID(uuidString: "1D5D590F-D8E1-49A9-AE17-2218A24234E0")!
    public static let vacuumID = UUID(uuidString: "C3D5EA8F-685F-4346-AF34-0D4C14656B86")!

    public static func defaults() -> [MaterialDefinition] {
        [
            MaterialDefinition(
                id: copperID,
                name: "Copper",
                color: RGBAColor(red: 0.78, green: 0.46, blue: 0.18),
                conductivity: 5.96e7
            ),
            MaterialDefinition(
                id: aluminumID,
                name: "Aluminum",
                color: RGBAColor(red: 0.70, green: 0.72, blue: 0.76),
                conductivity: 3.77e7
            ),
            MaterialDefinition(
                id: fr4ID,
                name: "FR4",
                color: RGBAColor(red: 0.20, green: 0.65, blue: 0.30, alpha: 0.80),
                epsilonR: 4.3
            ),
            MaterialDefinition(
                id: vacuumID,
                name: "Vacuum",
                color: RGBAColor(red: 0.55, green: 0.65, blue: 0.85, alpha: 0.15),
                epsilonR: 1.0
            )
        ]
    }
}
