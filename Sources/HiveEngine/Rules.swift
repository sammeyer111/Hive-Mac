import Foundation

/// Pure move generation and validation for Hive, including the
/// ladybug, mosquito, and pillbug expansion pieces.
public enum Rules {

    // MARK: - Public API

    /// All legal moves for the current player. Returns `[.pass]` when the
    /// player has no placement or movement available.
    public static func legalMoves(_ state: GameState) -> [Move] {
        guard state.outcome == nil else { return [] }
        var moves = legalPlacements(state)
        moves.append(contentsOf: legalMovements(state))
        return moves.isEmpty ? [.pass] : moves
    }

    /// Validates and applies a move, returning the new state.
    public static func apply(_ move: Move, to state: GameState) throws -> GameState {
        guard legalMoves(state).contains(move),
              let next = applyUnchecked(move, to: state) else {
            throw RuleError.illegalMove
        }
        return next
    }

    /// Applies a move without legality validation — for callers that already
    /// hold a move from `legalMoves` (bot search, replays). Returns nil only
    /// on structural mismatch (piece not where the move says).
    public static func applyUnchecked(_ move: Move, to state: GameState) -> GameState? {
        var next = state
        var movedID: String?
        var thrownID: String?

        switch move {
        case .place(let piece, let hex):
            next.board.push(piece, at: hex)
            next.hands[piece.color]?[piece.kind, default: 0] -= 1
            // Official FAQ: a just-placed piece counts as the opponent's most
            // recently moved piece, so a pillbug may not throw it next turn.
            movedID = piece.id
        case .move(let pieceID, let from, let to):
            guard let piece = next.board.pop(at: from), piece.id == pieceID else { return nil }
            next.board.push(piece, at: to)
            movedID = pieceID
        case .pillbugMove(_, let pieceID, let from, let to):
            guard let piece = next.board.pop(at: from), piece.id == pieceID else { return nil }
            next.board.push(piece, at: to)
            movedID = pieceID
            thrownID = pieceID
        case .pass:
            break
        }

        next.lastMovedPieceID = movedID
        next.immobilePieceID = thrownID
        next.movesPlayed.append(move)
        next.currentPlayer = state.currentPlayer.opponent
        next.outcome = computeOutcome(next)
        return next
    }

    public static func computeOutcome(_ state: GameState) -> Outcome? {
        let whiteDead = state.isQueenSurrounded(.white)
        let blackDead = state.isQueenSurrounded(.black)
        switch (whiteDead, blackDead) {
        case (true, true): return .draw
        case (true, false): return .win(.black)
        case (false, true): return .win(.white)
        case (false, false): return nil
        }
    }

    public enum RuleError: Error { case illegalMove }

    // MARK: - Placement

    public static func legalPlacements(_ state: GameState) -> [Move] {
        let color = state.currentPlayer
        let placed = state.placedCount(color)
        let mustPlaceQueen = placed == 3 && !state.queenPlaced(color)

        var kinds = PieceKind.allCases.filter { state.handCount(color, $0) > 0 }
        if mustPlaceQueen {
            kinds = kinds.filter { $0 == .queen }
        } else if placed == 0 {
            // Tournament rule: the queen may not be the opening placement.
            kinds = kinds.filter { $0 != .queen }
        }
        guard !kinds.isEmpty else { return [] }

        let targets = placementTargets(state)
        return kinds.flatMap { kind in
            let index = piecesUsed(state, color: color, kind: kind) + 1
            let piece = Piece(kind: kind, color: color, index: index)
            return targets.map { Move.place(piece: piece, at: $0) }
        }
    }

    public static func placementTargets(_ state: GameState) -> [Hex] {
        let board = state.board
        if board.isEmpty { return [Hex(0, 0)] }
        if board.pieceCount == 1 {
            // Second placement may touch the opposing first piece.
            return board.occupiedHexes[0].neighbors
        }
        let color = state.currentPlayer
        var candidates: Set<Hex> = []
        for hex in board.occupiedHexes where board.top(at: hex)?.color == color {
            for n in hex.neighbors where !board.isOccupied(n) {
                candidates.insert(n)
            }
        }
        return candidates.filter { hex in
            hex.neighbors.allSatisfy { board.top(at: $0)?.color != color.opponent }
        }.sorted { ($0.q, $0.r) < ($1.q, $1.r) }
    }

    private static func piecesUsed(_ state: GameState, color: PlayerColor, kind: PieceKind) -> Int {
        let total = state.config.pieceCounts[kind] ?? 0
        return total - state.handCount(color, kind)
    }

    // MARK: - Movement

    public static func legalMovements(_ state: GameState) -> [Move] {
        let color = state.currentPlayer
        guard state.queenPlaced(color) else { return [] }
        var moves: [Move] = []

        for hex in state.board.occupiedHexes {
            guard let piece = state.board.top(at: hex), piece.color == color else { continue }
            guard piece.id != state.immobilePieceID else { continue }
            guard state.board.remainsConnectedRemovingTop(at: hex) else { continue }
            for to in destinations(for: piece, at: hex, in: state) {
                moves.append(.move(pieceID: piece.id, from: hex, to: to))
            }
        }
        moves.append(contentsOf: pillbugThrows(state))
        return moves
    }

    /// Destinations for the top piece at `hex` (one-hive already verified by caller).
    public static func destinations(for piece: Piece, at hex: Hex, in state: GameState) -> [Hex] {
        let lifted = state.board.removingTop(at: hex)
        // Any piece on top of a stack moves as a beetle, including the mosquito.
        if state.board.height(at: hex) > 1 {
            if piece.kind == .beetle || piece.kind == .mosquito {
                return beetleTargets(from: hex, board: lifted)
            }
        }
        if piece.kind == .mosquito {
            var result: Set<Hex> = []
            for n in hex.neighbors {
                guard let copied = state.board.top(at: n)?.kind, copied != .mosquito else { continue }
                result.formUnion(targets(forKind: copied, from: hex, board: lifted))
            }
            return Array(result)
        }
        return targets(forKind: piece.kind, from: hex, board: lifted)
    }

    /// Movement targets for a bug of `kind` starting at `from`, where `board`
    /// already has the moving piece removed.
    static func targets(forKind kind: PieceKind, from: Hex, board: Board) -> [Hex] {
        switch kind {
        case .queen, .pillbug:
            return slideSteps(from: from, board: board)
        case .ant:
            return antTargets(from: from, board: board)
        case .spider:
            return spiderTargets(from: from, board: board)
        case .beetle:
            return beetleTargets(from: from, board: board)
        case .grasshopper:
            return grasshopperTargets(from: from, board: board)
        case .ladybug:
            return ladybugTargets(from: from, board: board)
        case .mosquito:
            return []  // handled by caller
        }
    }

    // MARK: Sliding

    /// Single ground-level slide steps from `from`. The moving piece must
    /// already be removed from `board`.
    static func slideSteps(from: Hex, board: Board) -> [Hex] {
        var result: [Hex] = []
        for (i, d) in Hex.directions.enumerated() {
            let to = from + d
            guard !board.isOccupied(to) else { continue }
            let g1 = from + Hex.directions[(i + 1) % 6]
            let g2 = from + Hex.directions[(i + 5) % 6]
            // Exactly one gate cell occupied: not blocked, and stays in
            // contact with the hive throughout the slide.
            if board.isOccupied(g1) != board.isOccupied(g2) {
                result.append(to)
            }
        }
        return result
    }

    static func antTargets(from: Hex, board: Board) -> [Hex] {
        var visited: Set<Hex> = [from]
        var frontier = [from]
        while let current = frontier.popLast() {
            for next in slideSteps(from: current, board: board) where !visited.contains(next) {
                visited.insert(next)
                frontier.append(next)
            }
        }
        visited.remove(from)
        return Array(visited)
    }

    static func spiderTargets(from: Hex, board: Board) -> [Hex] {
        var results: Set<Hex> = []
        func walk(_ current: Hex, _ path: Set<Hex>, _ depth: Int) {
            if depth == 3 {
                results.insert(current)
                return
            }
            for next in slideSteps(from: current, board: board) where !path.contains(next) {
                walk(next, path.union([next]), depth + 1)
            }
        }
        walk(from, [from], 0)
        return Array(results)
    }

    // MARK: Climbing (beetle-style gate rule)

    /// Whether a piece can step between adjacent hexes at height, where
    /// `fromHeight`/`toHeight` are the stack heights beneath the piece at each
    /// end (moving piece excluded). Blocked when both gate stacks are strictly
    /// taller than both ends.
    static func climbAllowed(from: Hex, to: Hex, fromHeight: Int, toHeight: Int, board: Board) -> Bool {
        let gates = from.commonNeighbors(with: to)
        guard gates.count == 2 else { return false }
        let level = max(fromHeight, toHeight)
        return !(board.height(at: gates[0]) > level && board.height(at: gates[1]) > level)
    }

    static func beetleTargets(from: Hex, board: Board) -> [Hex] {
        let fromHeight = board.height(at: from)  // beetle already removed
        var result: [Hex] = []
        for (i, d) in Hex.directions.enumerated() {
            let to = from + d
            let toHeight = board.height(at: to)
            if fromHeight == 0 && toHeight == 0 {
                // Ground-to-ground: same constraints as a slide.
                let g1 = from + Hex.directions[(i + 1) % 6]
                let g2 = from + Hex.directions[(i + 5) % 6]
                if board.isOccupied(g1) != board.isOccupied(g2) {
                    result.append(to)
                }
            } else {
                if climbAllowed(from: from, to: to, fromHeight: fromHeight, toHeight: toHeight, board: board) {
                    result.append(to)
                }
            }
        }
        return result
    }

    static func grasshopperTargets(from: Hex, board: Board) -> [Hex] {
        var result: [Hex] = []
        for d in Hex.directions {
            var probe = from + d
            guard board.isOccupied(probe) else { continue }
            while board.isOccupied(probe) { probe = probe + d }
            result.append(probe)
        }
        return result
    }

    static func ladybugTargets(from: Hex, board: Board) -> [Hex] {
        var result: Set<Hex> = []
        for n1 in from.neighbors where board.isOccupied(n1) {
            guard climbAllowed(from: from, to: n1, fromHeight: board.height(at: from),
                               toHeight: board.height(at: n1), board: board) else { continue }
            for n2 in n1.neighbors where board.isOccupied(n2) {
                guard climbAllowed(from: n1, to: n2, fromHeight: board.height(at: n1),
                                   toHeight: board.height(at: n2), board: board) else { continue }
                for n3 in n2.neighbors where !board.isOccupied(n3) && n3 != from {
                    guard climbAllowed(from: n2, to: n3, fromHeight: board.height(at: n2),
                                       toHeight: 0, board: board) else { continue }
                    result.insert(n3)
                }
            }
        }
        return Array(result)
    }

    // MARK: Pillbug ability

    public static func pillbugThrows(_ state: GameState) -> [Move] {
        let color = state.currentPlayer
        guard state.queenPlaced(color) else { return [] }
        var moves: [Move] = []

        for hex in state.board.occupiedHexes {
            guard let piece = state.board.top(at: hex), piece.color == color else { continue }
            guard piece.id != state.immobilePieceID else { continue }
            let isPillbug = piece.kind == .pillbug
            // A ground-level mosquito touching any pillbug copies the ability.
            let isCopyingMosquito = piece.kind == .mosquito
                && state.board.height(at: hex) == 1
                && hex.neighbors.contains { state.board.top(at: $0)?.kind == .pillbug }
            guard isPillbug || isCopyingMosquito else { continue }
            moves.append(contentsOf: throwMoves(by: piece, at: hex, in: state))
        }
        return moves
    }

    private static func throwMoves(by pillbug: Piece, at p: Hex, in state: GameState) -> [Move] {
        let board = state.board
        var moves: [Move] = []
        for v in p.neighbors where board.height(at: v) == 1 {
            guard let victim = board.top(at: v) else { continue }
            guard victim.id != state.lastMovedPieceID, victim.id != state.immobilePieceID else { continue }
            guard board.remainsConnectedRemovingTop(at: v) else { continue }
            let lifted = board.removingTop(at: v)
            // Up onto the pillbug...
            guard climbAllowed(from: v, to: p, fromHeight: 0,
                               toHeight: lifted.height(at: p), board: lifted) else { continue }
            // ...then down into an empty neighbor.
            for d in p.neighbors where !lifted.isOccupied(d) && d != v {
                guard climbAllowed(from: p, to: d, fromHeight: lifted.height(at: p),
                                   toHeight: 0, board: lifted) else { continue }
                moves.append(.pillbugMove(pillbugID: pillbug.id, pieceID: victim.id, from: v, to: d))
            }
        }
        return moves
    }
}
