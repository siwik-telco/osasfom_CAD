import Foundation

/// A colour, kept free of AppKit so Core stays headless.
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

public enum MaterialKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Ordinary (possibly lossy, possibly dispersive) medium.
    case dielectric
    /// Perfect electric conductor — a boundary condition, not a finite σ. Kept
    /// as its own kind so a mesher never has to guess whether a huge
    /// conductivity "means" PEC.
    case perfectElectricConductor
    /// Perfect magnetic conductor.
    case perfectMagneticConductor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dielectric: return "Dielectric / conductor"
        case .perfectElectricConductor: return "PEC"
        case .perfectMagneticConductor: return "PMC"
        }
    }

    /// PEC/PMC are boundary conditions; ε, µ and σ are meaningless for them.
    public var usesConstitutiveParameters: Bool { self == .dielectric }
}

public struct DebyePole: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    /// Permittivity increment for this pole.
    public var deltaEpsilon: Double
    /// Relaxation time, seconds.
    public var relaxationTimeSeconds: Double

    public init(id: UUID = UUID(), deltaEpsilon: Double, relaxationTimeSeconds: Double) {
        self.id = id
        self.deltaEpsilon = deltaEpsilon
        self.relaxationTimeSeconds = relaxationTimeSeconds
    }
}

public struct LorentzPole: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var deltaEpsilon: Double
    /// Resonance frequency, Hz.
    public var resonanceHertz: Double
    /// Damping (collision) frequency, Hz.
    public var dampingHertz: Double

    public init(
        id: UUID = UUID(),
        deltaEpsilon: Double,
        resonanceHertz: Double,
        dampingHertz: Double
    ) {
        self.id = id
        self.deltaEpsilon = deltaEpsilon
        self.resonanceHertz = resonanceHertz
        self.dampingHertz = dampingHertz
    }
}

/// Frequency dependence of the permittivity.
///
/// `epsilonR` on the material is the high-frequency limit (ε∞) whenever a
/// dispersion model is present.
public enum DispersionModel: Codable, Hashable, Sendable {
    case none
    case debye(poles: [DebyePole])
    case drude(plasmaHertz: Double, collisionHertz: Double)
    case lorentz(poles: [LorentzPole])

    public var displayName: String {
        switch self {
        case .none: return "None (non-dispersive)"
        case .debye: return "Debye"
        case .drude: return "Drude"
        case .lorentz: return "Lorentz"
        }
    }

    public var isNone: Bool {
        if case .none = self { return true }
        return false
    }
}

/// An FDTD material.
///
/// Carries what a time-domain solver actually needs: ε_r, µ_r, electric and
/// magnetic loss, an explicit PEC/PMC flag, and an optional dispersion model.
public struct MaterialDefinition: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var color: RGBAColor
    public var kind: MaterialKind
    /// Relative permittivity (ε∞ when dispersive).
    public var epsilonR: Double
    /// Relative permeability.
    public var muR: Double
    /// Electric conductivity, S/m.
    public var electricConductivity: Double
    /// Magnetic conductivity, ohm/m.
    public var magneticConductivity: Double
    public var dispersion: DispersionModel
    /// Free-form provenance note, e.g. a datasheet reference.
    public var reference: String

    public init(
        id: UUID = UUID(),
        name: String,
        color: RGBAColor,
        kind: MaterialKind = .dielectric,
        epsilonR: Double = 1,
        muR: Double = 1,
        electricConductivity: Double = 0,
        magneticConductivity: Double = 0,
        dispersion: DispersionModel = .none,
        reference: String = ""
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.kind = kind
        self.epsilonR = epsilonR
        self.muR = muR
        self.electricConductivity = electricConductivity
        self.magneticConductivity = magneticConductivity
        self.dispersion = dispersion
        self.reference = reference
    }

    /// Loss tangent at `hertz`, for the non-dispersive case.
    public func lossTangent(atHertz hertz: Double) -> Double? {
        guard kind == .dielectric, hertz > 0, epsilonR > 0 else { return nil }
        let omega = 2 * Double.pi * hertz
        let epsilonAbsolute = epsilonR * 8.854_187_812_8e-12
        return electricConductivity / (omega * epsilonAbsolute)
    }

    /// Sets `electricConductivity` from a loss tangent at a reference frequency.
    ///
    /// The result is rounded to 12 significant digits. That is far below any
    /// physical relevance but keeps the value safely inside what Foundation's
    /// `JSONEncoder` can round-trip — its 17-digit output does not always decode
    /// back to the same `Double`, which would otherwise perturb a material every
    /// time the project was saved and reopened.
    public mutating func setLossTangent(_ tangent: Double, atHertz hertz: Double) {
        guard hertz > 0 else { return }
        let omega = 2 * Double.pi * hertz
        let conductivity = tangent * omega * epsilonR * 8.854_187_812_8e-12
        electricConductivity = Self.roundedToSignificantDigits(conductivity, digits: 12)
    }

    static func roundedToSignificantDigits(_ value: Double, digits: Int) -> Double {
        guard value != 0, value.isFinite else { return value }
        let exponent = (log10(abs(value))).rounded(.down)
        let factor = pow(10.0, Double(digits - 1) - exponent)
        guard factor.isFinite, factor != 0 else { return value }
        return (value * factor).rounded() / factor
    }

    /// Decodes tolerantly so files written by the earlier prototype — where
    /// `epsilonR` and `conductivity` were optional and nothing else existed —
    /// still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decode(RGBAColor.self, forKey: .color)
        kind = try container.decodeIfPresent(MaterialKind.self, forKey: .kind) ?? .dielectric
        epsilonR = try container.decodeIfPresent(Double.self, forKey: .epsilonR) ?? 1
        muR = try container.decodeIfPresent(Double.self, forKey: .muR) ?? 1
        electricConductivity = try container.decodeIfPresent(
            Double.self,
            forKey: .electricConductivity
        ) ?? container.decodeIfPresent(Double.self, forKey: .legacyConductivity) ?? 0
        magneticConductivity = try container.decodeIfPresent(
            Double.self,
            forKey: .magneticConductivity
        ) ?? 0
        dispersion = try container.decodeIfPresent(DispersionModel.self, forKey: .dispersion) ?? .none
        reference = try container.decodeIfPresent(String.self, forKey: .reference) ?? ""
    }

    /// Written explicitly because `legacyConductivity` is a read-only alias with
    /// no stored property behind it, so the encoder cannot be synthesised.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(color, forKey: .color)
        try container.encode(kind, forKey: .kind)
        try container.encode(epsilonR, forKey: .epsilonR)
        try container.encode(muR, forKey: .muR)
        try container.encode(electricConductivity, forKey: .electricConductivity)
        try container.encode(magneticConductivity, forKey: .magneticConductivity)
        try container.encode(dispersion, forKey: .dispersion)
        try container.encode(reference, forKey: .reference)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case color
        case kind
        case epsilonR
        case muR
        case electricConductivity
        case magneticConductivity
        case dispersion
        case reference
        case legacyConductivity = "conductivity"
    }
}

public enum MaterialLibrary {
    // Stable IDs so exports and saved projects keep resolving. The first four
    // match the original prototype's IDs.
    public static let copperID = UUID(uuidString: "9F848155-FB5D-4D34-B7AF-689A43CBEA01")!
    public static let aluminumID = UUID(uuidString: "3AD78F26-F2F1-489A-B145-09C7B0D8DCC2")!
    public static let fr4ID = UUID(uuidString: "1D5D590F-D8E1-49A9-AE17-2218A24234E0")!
    public static let vacuumID = UUID(uuidString: "C3D5EA8F-685F-4346-AF34-0D4C14656B86")!
    public static let pecID = UUID(uuidString: "6E2A7D41-4C3B-45F0-9E8D-1B7A5C2F3D90")!
    public static let rogers4003CID = UUID(uuidString: "0A9C1E77-2B54-4E1A-8F63-7D4B0C5A9E12")!
    public static let ptfeID = UUID(uuidString: "B4F0D2A8-51E6-4C93-A70F-8C1D6E2B4A55")!

    /// The material used for a body with no explicit assignment. Making this
    /// explicit removes the old ambiguity of what `materialID == nil` meant to
    /// the solver.
    public static let defaultMaterialID = vacuumID

    public static func defaults() -> [MaterialDefinition] {
        [
            MaterialDefinition(
                id: vacuumID,
                name: "Vacuum",
                color: RGBAColor(red: 0.55, green: 0.65, blue: 0.85, alpha: 0.15),
                kind: .dielectric,
                epsilonR: 1.0,
                muR: 1.0
            ),
            MaterialDefinition(
                id: pecID,
                name: "PEC",
                color: RGBAColor(red: 0.95, green: 0.85, blue: 0.35),
                kind: .perfectElectricConductor,
                reference: "Perfect electric conductor boundary"
            ),
            MaterialDefinition(
                id: copperID,
                name: "Copper",
                color: RGBAColor(red: 0.78, green: 0.46, blue: 0.18),
                kind: .dielectric,
                epsilonR: 1.0,
                muR: 1.0,
                electricConductivity: 5.96e7,
                reference: "σ at 20 °C"
            ),
            MaterialDefinition(
                id: aluminumID,
                name: "Aluminum",
                color: RGBAColor(red: 0.70, green: 0.72, blue: 0.76),
                kind: .dielectric,
                epsilonR: 1.0,
                muR: 1.0,
                electricConductivity: 3.77e7,
                reference: "σ at 20 °C"
            ),
            fr4(),
            MaterialDefinition(
                id: rogers4003CID,
                name: "Rogers RO4003C",
                color: RGBAColor(red: 0.85, green: 0.78, blue: 0.55, alpha: 0.85),
                kind: .dielectric,
                epsilonR: 3.55,
                muR: 1.0,
                electricConductivity: 0.000_986,
                reference: "εr 3.55, tanδ 0.0027 @ 10 GHz"
            ),
            MaterialDefinition(
                id: ptfeID,
                name: "PTFE",
                color: RGBAColor(red: 0.92, green: 0.92, blue: 0.94, alpha: 0.75),
                kind: .dielectric,
                epsilonR: 2.1,
                muR: 1.0,
                electricConductivity: 0.000_023,
                reference: "εr 2.1, tanδ 0.0002 @ 10 GHz"
            )
        ]
    }

    private static func fr4() -> MaterialDefinition {
        var material = MaterialDefinition(
            id: fr4ID,
            name: "FR-4",
            color: RGBAColor(red: 0.20, green: 0.65, blue: 0.30, alpha: 0.80),
            kind: .dielectric,
            epsilonR: 4.3,
            muR: 1.0,
            reference: "εr 4.3, tanδ 0.02 @ 1 GHz"
        )
        material.setLossTangent(0.02, atHertz: 1e9)
        return material
    }

    public static var vacuum: MaterialDefinition {
        defaults().first { $0.id == vacuumID }!
    }
}
