import Foundation

/// Standard Hive move notation (UHP style): a move is written as the moving
/// piece followed by a reference neighbor of the destination with a direction
/// marker — `wA1 bQ/` places white's first ant northeast of the black queen.
/// Markers: `x-` E, `x/` NE, `\x` NW, `-x` W, `/x` SW, `x\` SE; climbing onto
/// a piece uses its bare name. Pillbug throws are suffixed with `!`.
public enum Notation {

    public static func describe(_ move: Move, before state: GameState) -> String {
        switch move {
        case .pass:
            return "pass"
        case .place(let piece, let at):
            let ref = reference(for: at, state: state, vacating: nil)
            return ref.isEmpty ? shortID(piece.id) : "\(shortID(piece.id)) \(ref)"
        case .move(let pieceID, let from, let to):
            return "\(shortID(pieceID)) \(reference(for: to, state: state, vacating: from))"
        case .pillbugMove(_, let pieceID, let from, let to):
            return "\(shortID(pieceID)) \(reference(for: to, state: state, vacating: from))!"
        }
    }

    /// Notations for a whole game, replaying from the starting position.
    public static func list(moves: [Move], config: GameConfig, startingPlayer: PlayerColor) -> [String] {
        var state = GameState(config: config, startingPlayer: startingPlayer)
        var result: [String] = []
        for move in moves {
            result.append(describe(move, before: state))
            guard let next = Rules.applyUnchecked(move, to: state) else { break }
            state = next
        }
        return result
    }

    /// "wQ1" → "wQ" for pieces a player only has one of; indexed otherwise.
    public static func shortID(_ id: String) -> String {
        guard id.count == 3, id.hasSuffix("1") else { return id }
        let kind = id[id.index(id.startIndex, offsetBy: 1)]
        return "QMLP".contains(kind) ? String(id.dropLast()) : id
    }

    private static func reference(for destination: Hex, state: GameState, vacating from: Hex?) -> String {
        let board = state.board
        if board.isEmpty { return "" }
        // Climbing onto an occupied hex: the reference is the piece beneath.
        if let top = board.top(at: destination) { return shortID(top.id) }
        for (i, dir) in Hex.directions.enumerated() {
            let neighbor = destination + dir
            var height = board.height(at: neighbor)
            var stack = board.stack(at: neighbor)
            if neighbor == from {
                // The mover leaves this hex; reference what remains, if anything.
                height -= 1
                stack = Array(stack.dropLast())
            }
            guard height > 0, let ref = stack.last else { continue }
            // The destination sits opposite direction i from the reference.
            return marked(shortID(ref.id), directionIndex: (i + 3) % 6)
        }
        return ""
    }

    private static func marked(_ name: String, directionIndex: Int) -> String {
        switch directionIndex {  // directions: 0 E, 1 NE, 2 NW, 3 W, 4 SW, 5 SE
        case 0: return "\(name)-"
        case 1: return "\(name)/"
        case 2: return "\\\(name)"
        case 3: return "-\(name)"
        case 4: return "/\(name)"
        case 5: return "\(name)\\"
        default: return name
        }
    }
}
