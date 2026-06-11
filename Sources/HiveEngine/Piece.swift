import Foundation

public enum PlayerColor: String, Codable, Hashable, Sendable, CaseIterable {
    case white, black

    public var opponent: PlayerColor { self == .white ? .black : .white }
    public var idPrefix: String { self == .white ? "w" : "b" }
    public var displayName: String { rawValue.capitalized }
}

public enum PieceKind: String, Codable, Hashable, Sendable, CaseIterable {
    case queen, ant, spider, beetle, grasshopper, mosquito, ladybug, pillbug

    public var letter: String {
        switch self {
        case .queen: return "Q"
        case .ant: return "A"
        case .spider: return "S"
        case .beetle: return "B"
        case .grasshopper: return "G"
        case .mosquito: return "M"
        case .ladybug: return "L"
        case .pillbug: return "P"
        }
    }

    public var displayName: String {
        switch self {
        case .queen: return "Queen Bee"
        case .ant: return "Soldier Ant"
        case .spider: return "Spider"
        case .beetle: return "Beetle"
        case .grasshopper: return "Grasshopper"
        case .mosquito: return "Mosquito"
        case .ladybug: return "Ladybug"
        case .pillbug: return "Pillbug"
        }
    }

    public var emoji: String {
        switch self {
        case .queen: return "🐝"
        case .ant: return "🐜"
        case .spider: return "🕷️"
        case .beetle: return "🪲"
        case .grasshopper: return "🦗"
        case .mosquito: return "🦟"
        case .ladybug: return "🐞"
        case .pillbug: return "💊"
        }
    }

    /// Piece counts per player for the classic game.
    public static let classicCounts: [PieceKind: Int] = [
        .queen: 1, .ant: 3, .spider: 2, .beetle: 2, .grasshopper: 3,
    ]

    /// Piece counts per player with the ladybug, mosquito and pillbug expansions.
    public static let fullCounts: [PieceKind: Int] = classicCounts.merging(
        [.mosquito: 1, .ladybug: 1, .pillbug: 1], uniquingKeysWith: { a, _ in a })

    /// Stable ordering for UI trays.
    public static let trayOrder: [PieceKind] = [
        .queen, .ant, .spider, .beetle, .grasshopper, .ladybug, .mosquito, .pillbug,
    ]
}

public struct Piece: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let kind: PieceKind
    public let color: PlayerColor

    public init(kind: PieceKind, color: PlayerColor, index: Int) {
        self.kind = kind
        self.color = color
        self.id = "\(color.idPrefix)\(kind.letter)\(index)"
    }
}
