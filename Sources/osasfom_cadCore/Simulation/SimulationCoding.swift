import Foundation

// Hand-written Codable conformances for the enums that carry payloads.
//
// The synthesised form nests under the case name (`{"box": {"_0": …}}`), which
// is awkward for anything outside Swift to read. Since the project file and the
// solver export are a contract with the solver, both use a flat `type`
// discriminator instead.

extension MonitorRegion {
    private enum CodingKeys: String, CodingKey {
        case type
        case axis
        case position
        case bounds
    }

    private enum RegionType: String, Codable {
        case wholeDomain
        case box
        case plane
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(RegionType.self, forKey: .type) {
        case .wholeDomain:
            self = .wholeDomain
        case .box:
            self = .box(try container.decode(BoundsExpression.self, forKey: .bounds))
        case .plane:
            self = .plane(
                axis: try container.decode(Axis.self, forKey: .axis),
                position: try container.decode(Expression.self, forKey: .position)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .wholeDomain:
            try container.encode(RegionType.wholeDomain, forKey: .type)
        case .box(let bounds):
            try container.encode(RegionType.box, forKey: .type)
            try container.encode(bounds, forKey: .bounds)
        case .plane(let axis, let position):
            try container.encode(RegionType.plane, forKey: .type)
            try container.encode(axis, forKey: .axis)
            try container.encode(position, forKey: .position)
        }
    }
}

extension DispersionModel {
    private enum CodingKeys: String, CodingKey {
        case type
        case poles
        case plasmaHertz
        case collisionHertz
    }

    private enum ModelType: String, Codable {
        case none
        case debye
        case drude
        case lorentz
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ModelType.self, forKey: .type) {
        case .none:
            self = .none
        case .debye:
            self = .debye(poles: try container.decode([DebyePole].self, forKey: .poles))
        case .drude:
            self = .drude(
                plasmaHertz: try container.decode(Double.self, forKey: .plasmaHertz),
                collisionHertz: try container.decode(Double.self, forKey: .collisionHertz)
            )
        case .lorentz:
            self = .lorentz(poles: try container.decode([LorentzPole].self, forKey: .poles))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(ModelType.none, forKey: .type)
        case .debye(let poles):
            try container.encode(ModelType.debye, forKey: .type)
            try container.encode(poles, forKey: .poles)
        case .drude(let plasmaHertz, let collisionHertz):
            try container.encode(ModelType.drude, forKey: .type)
            try container.encode(plasmaHertz, forKey: .plasmaHertz)
            try container.encode(collisionHertz, forKey: .collisionHertz)
        case .lorentz(let poles):
            try container.encode(ModelType.lorentz, forKey: .type)
            try container.encode(poles, forKey: .poles)
        }
    }
}
