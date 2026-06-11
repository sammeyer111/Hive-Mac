import Foundation

public struct GameConfig: Hashable, Codable, Sendable {
    public enum FirstMove: String, Codable, Hashable, Sendable, CaseIterable {
        case white, black, random

        public var displayName: String { rawValue.capitalized }
    }

    /// Full game adds the ladybug, mosquito, and pillbug.
    public var useExpansions: Bool
    /// Seconds allowed per turn; nil = untimed.
    public var turnSeconds: Int?
    public var firstMove: FirstMove

    public init(useExpansions: Bool = false, turnSeconds: Int? = nil, firstMove: FirstMove = .white) {
        self.useExpansions = useExpansions
        self.turnSeconds = turnSeconds
        self.firstMove = firstMove
    }

    /// Concrete starting color, resolving `.random` (called once, by the host).
    public func resolveStartingPlayer() -> PlayerColor {
        switch firstMove {
        case .white: return .white
        case .black: return .black
        case .random: return Bool.random() ? .white : .black
        }
    }

    public var pieceCounts: [PieceKind: Int] {
        useExpansions ? PieceKind.fullCounts : PieceKind.classicCounts
    }
}

public enum Move: Hashable, Codable, Sendable {
    case place(piece: Piece, at: Hex)
    case move(pieceID: String, from: Hex, to: Hex)
    /// Pillbug (or mosquito copying one) lifts an adjacent piece and sets it down elsewhere.
    case pillbugMove(pillbugID: String, pieceID: String, from: Hex, to: Hex)
    case pass

    /// Hex the move ends on, if any (for UI highlighting).
    public var destination: Hex? {
        switch self {
        case .place(_, let at): return at
        case .move(_, _, let to): return to
        case .pillbugMove(_, _, _, let to): return to
        case .pass: return nil
        }
    }
}

public enum Outcome: Hashable, Codable, Sendable {
    case win(PlayerColor)
    case draw
}

public struct GameState: Codable, Sendable {
    public var config: GameConfig
    public var board: Board
    public var hands: [PlayerColor: [PieceKind: Int]]
    public var currentPlayer: PlayerColor
    public var movesPlayed: [Move]
    /// Piece moved, thrown, or placed on the immediately previous turn; a pillbug may not throw it.
    public var lastMovedPieceID: String?
    /// Piece thrown by a pillbug on the previous turn; it may not move or act this turn.
    public var immobilePieceID: String?
    public var outcome: Outcome?

    public init(config: GameConfig, startingPlayer: PlayerColor) {
        self.config = config
        self.board = Board()
        let counts = config.pieceCounts
        self.hands = [.white: counts, .black: counts]
        self.currentPlayer = startingPlayer
        self.movesPlayed = []
    }

    public func handCount(_ color: PlayerColor, _ kind: PieceKind) -> Int {
        hands[color]?[kind] ?? 0
    }

    /// Number of pieces this color has placed on the board so far.
    public func placedCount(_ color: PlayerColor) -> Int {
        let total = config.pieceCounts.values.reduce(0, +)
        let inHand = hands[color]?.values.reduce(0, +) ?? 0
        return total - inHand
    }

    public func queenPlaced(_ color: PlayerColor) -> Bool {
        handCount(color, .queen) == 0
    }

    public func queenPosition(_ color: PlayerColor) -> Hex? {
        board.position(ofPieceID: "\(color.idPrefix)Q1")
    }

    public func isQueenSurrounded(_ color: PlayerColor) -> Bool {
        guard let pos = queenPosition(color) else { return false }
        return pos.neighbors.allSatisfy { board.isOccupied($0) }
    }
}
