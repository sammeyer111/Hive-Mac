import Foundation

/// Alpha-beta search engine for Hive, shared by the in-game opponent and the
/// post-game analyzer. Pure and deterministic (given the same limits), so it
/// is fully unit-testable.
///
/// Design: iterative-deepening negamax with alpha-beta pruning, a transposition
/// table keyed by a translation-normalized Zobrist hash, and move ordering
/// (TT move → queen-attacking moves → killer/history heuristics). The
/// evaluation is positional — Hive has no material — built around queen
/// surroundedness, piece mobility (pinned pieces found in one articulation-
/// point pass), and beetle pins.
/// Tunable evaluation parameters. The background trainer evolves these via
/// self-play; the app loads the tuned set at startup. A weight tuned to ~0
/// effectively removes its attribute from the AI's judgment.
public struct EvalWeights: Codable, Sendable, Equatable {
    /// Value of having n of a queen's six neighbors filled (index 0...6).
    public var surround: [Double]
    /// Bonus per enemy-queen neighbor that is ours.
    public var ownQueenAdjacency: Double
    /// Sitting on top of the enemy queen.
    public var beetlePin: Double
    /// Per enemy piece pinned by the one-hive rule.
    public var pinnedPiece: Double
    /// Side-to-move nudge.
    public var tempo: Double
    /// Per empty cell the queen can actually slide to.
    public var escapeRoute: Double
    /// The queen itself cannot move at all (load-bearing or covered).
    public var queenPinned: Double
    /// Per free (unpinned, uncovered) ant — the game's best attacker.
    public var freeAnt: Double
    /// Per free beetle.
    public var freeBeetle: Double
    /// Per free piece of any other kind (queen excluded).
    public var freeOther: Double
    /// Per free beetle/mosquito within 2 hexes of the enemy queen.
    public var beetleAdvance: Double
    /// Per cell where new pieces may legally be placed.
    public var placementSpot: Double
    /// Per non-queen piece buried under an enemy piece.
    public var coveredPiece: Double
    /// Own pillbug standing next to the own queen (defensive eject threat).
    public var pillbugGuard: Double

    public init(surround: [Double] = [0, 12, 30, 58, 110, 260, 1000],
                ownQueenAdjacency: Double = 6,
                beetlePin: Double = 40,
                pinnedPiece: Double = 4,
                tempo: Double = 2,
                escapeRoute: Double = 12,
                queenPinned: Double = 60,
                freeAnt: Double = 6,
                freeBeetle: Double = 5,
                freeOther: Double = 1.5,
                beetleAdvance: Double = 12,
                placementSpot: Double = 1.5,
                coveredPiece: Double = 7,
                pillbugGuard: Double = 10) {
        self.surround = surround
        self.ownQueenAdjacency = ownQueenAdjacency
        self.beetlePin = beetlePin
        self.pinnedPiece = pinnedPiece
        self.tempo = tempo
        self.escapeRoute = escapeRoute
        self.queenPinned = queenPinned
        self.freeAnt = freeAnt
        self.freeBeetle = freeBeetle
        self.freeOther = freeOther
        self.beetleAdvance = beetleAdvance
        self.placementSpot = placementSpot
        self.coveredPiece = coveredPiece
        self.pillbugGuard = pillbugGuard
    }

    public static let `default` = EvalWeights()

    /// Backward-compatible decoding: weight files written before an attribute
    /// existed load fine, with the new attribute at its default — so adding
    /// attributes never throws away training progress.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EvalWeights.default
        surround = try c.decodeIfPresent([Double].self, forKey: .surround) ?? d.surround
        if surround.count != 7 { surround = d.surround }
        ownQueenAdjacency = try c.decodeIfPresent(Double.self, forKey: .ownQueenAdjacency) ?? d.ownQueenAdjacency
        beetlePin = try c.decodeIfPresent(Double.self, forKey: .beetlePin) ?? d.beetlePin
        pinnedPiece = try c.decodeIfPresent(Double.self, forKey: .pinnedPiece) ?? d.pinnedPiece
        tempo = try c.decodeIfPresent(Double.self, forKey: .tempo) ?? d.tempo
        escapeRoute = try c.decodeIfPresent(Double.self, forKey: .escapeRoute) ?? d.escapeRoute
        queenPinned = try c.decodeIfPresent(Double.self, forKey: .queenPinned) ?? d.queenPinned
        freeAnt = try c.decodeIfPresent(Double.self, forKey: .freeAnt) ?? d.freeAnt
        freeBeetle = try c.decodeIfPresent(Double.self, forKey: .freeBeetle) ?? d.freeBeetle
        freeOther = try c.decodeIfPresent(Double.self, forKey: .freeOther) ?? d.freeOther
        beetleAdvance = try c.decodeIfPresent(Double.self, forKey: .beetleAdvance) ?? d.beetleAdvance
        placementSpot = try c.decodeIfPresent(Double.self, forKey: .placementSpot) ?? d.placementSpot
        coveredPiece = try c.decodeIfPresent(Double.self, forKey: .coveredPiece) ?? d.coveredPiece
        pillbugGuard = try c.decodeIfPresent(Double.self, forKey: .pillbugGuard) ?? d.pillbugGuard
    }
}

public final class HiveAI {

    public let weights: EvalWeights

    // Score scale: roughly "centi-liberty" units. Wins are near ±WIN, offset
    // by ply so the engine prefers faster wins / slower losses.
    public static let win = 1_000_000
    public static let maxPlyOffset = 1000

    public struct Limits: Sendable {
        public var maxDepth: Int
        public var maxTime: TimeInterval
        public init(maxDepth: Int = 64, maxTime: TimeInterval = 1.5) {
            self.maxDepth = maxDepth
            self.maxTime = maxTime
        }
    }

    public struct Result: Sendable {
        public var bestMove: Move?
        /// Score from the searching player's perspective (positive = good).
        public var score: Int
        public var depth: Int
        public var nodes: Int
    }

    // Transposition table.
    private enum Bound: UInt8 { case exact, lower, upper }
    private struct TTEntry {
        var key: UInt64
        var depth: Int16
        var score: Int32
        var bound: Bound
        var move: Move?
    }
    private var tt: [TTEntry?]
    private let ttMask: Int

    // Search bookkeeping (reset per search).
    private var deadline: Date = .distantFuture
    private var aborted = false
    private var nodes = 0
    private var killers: [[Move?]] = []
    private var history: [Int: Int] = [:]
    private let clockCheckInterval = 2048

    /// `sizeMB` bounds the transposition table.
    public init(sizeMB: Int = 64, weights: EvalWeights = .default) {
        self.weights = weights
        let entries = max(1 << 12, (sizeMB * 1_048_576) / MemoryLayout<TTEntry?>.stride)
        // Round down to a power of two for fast masking.
        var pow2 = 1
        while pow2 << 1 <= entries { pow2 <<= 1 }
        tt = Array(repeating: nil, count: pow2)
        ttMask = pow2 - 1
    }

    // MARK: - Public search

    public func search(_ state: GameState, limits: Limits) -> Result {
        deadline = Date().addingTimeInterval(limits.maxTime)
        aborted = false
        nodes = 0
        killers = Array(repeating: [nil, nil], count: limits.maxDepth + 64)
        history.removeAll(keepingCapacity: true)

        let rootMoves = Rules.legalMoves(state)
        if rootMoves.isEmpty { return Result(bestMove: nil, score: 0, depth: 0, nodes: 0) }
        if rootMoves.count == 1 {
            return Result(bestMove: rootMoves[0], score: 0, depth: 1, nodes: 1)
        }

        var best = Result(bestMove: rootMoves[0], score: 0, depth: 0, nodes: 0)

        // Iterative deepening: each completed depth refines the best move and
        // seeds move ordering for the next.
        for depth in 1...limits.maxDepth {
            let (move, score, completed) = searchRoot(state, depth: depth, rootMoves: rootMoves,
                                                      previousBest: best.bestMove)
            if completed {
                best = Result(bestMove: move, score: score, depth: depth, nodes: nodes)
                // Stop early on a proven win/loss; deeper search can't change it.
                if abs(score) > Self.win - Self.maxPlyOffset { break }
            }
            if aborted || Date() >= deadline { break }
        }
        best.nodes = nodes
        return best
    }

    /// Convenience: best move only.
    public func bestMove(_ state: GameState, limits: Limits) -> Move? {
        search(state, limits: limits).bestMove
    }

    // MARK: - Root

    private func searchRoot(_ state: GameState, depth: Int, rootMoves: [Move],
                            previousBest: Move?) -> (Move?, Int, Bool) {
        var alpha = -Self.win * 2
        let beta = Self.win * 2
        var bestMove = rootMoves[0]
        var bestScore = -Self.win * 2

        let ordered = orderMoves(rootMoves, state: state, ttMove: previousBest, ply: 0)
        for move in ordered {
            guard let child = Rules.applyUnchecked(move, to: state) else { continue }
            let score = -negamax(child, depth: depth - 1, alpha: -beta, beta: -alpha, ply: 1)
            if aborted { return (bestMove, bestScore, false) }
            if score > bestScore {
                bestScore = score
                bestMove = move
            }
            if score > alpha { alpha = score }
        }
        return (bestMove, bestScore, true)
    }

    // MARK: - Negamax

    private func negamax(_ state: GameState, depth: Int, alpha: Int, beta: Int, ply: Int) -> Int {
        if let outcome = state.outcome {
            return terminalScore(outcome, for: state.currentPlayer, ply: ply)
        }
        nodes += 1
        if nodes % clockCheckInterval == 0, Date() >= deadline {
            aborted = true
            return 0
        }
        if depth <= 0 {
            return evaluate(state)
        }

        var alpha = alpha
        let key = zobrist(state)
        let slot = Int(key & UInt64(ttMask))
        var ttMove: Move?
        if let entry = tt[slot], entry.key == key {
            ttMove = entry.move
            if Int(entry.depth) >= depth {
                let score = Int(entry.score)
                switch entry.bound {
                case .exact: return score
                case .lower: if score >= beta { return score }
                case .upper: if score <= alpha { return score }
                }
            }
        }

        let moves = Rules.legalMoves(state)
        if moves.isEmpty { return evaluate(state) }

        let ordered = orderMoves(moves, state: state, ttMove: ttMove, ply: ply)
        var bestScore = -Self.win * 2
        var bestMove: Move?
        let originalAlpha = alpha

        for move in ordered {
            guard let child = Rules.applyUnchecked(move, to: state) else { continue }
            let score = -negamax(child, depth: depth - 1, alpha: -beta, beta: -alpha, ply: ply + 1)
            if aborted { return bestScore == -Self.win * 2 ? alpha : bestScore }
            if score > bestScore {
                bestScore = score
                bestMove = move
            }
            if score > alpha { alpha = score }
            if alpha >= beta {
                recordCutoff(move, ply: ply, depth: depth)
                break
            }
        }

        let bound: Bound = bestScore <= originalAlpha ? .upper : (bestScore >= beta ? .lower : .exact)
        store(key: key, slot: slot, depth: depth, score: bestScore, bound: bound, move: bestMove)
        return bestScore
    }

    private func terminalScore(_ outcome: Outcome, for player: PlayerColor, ply: Int) -> Int {
        switch outcome {
        case .draw: return 0
        case .win(let color):
            let mag = Self.win - ply
            return color == player ? mag : -mag
        }
    }

    private func store(key: UInt64, slot: Int, depth: Int, score: Int, bound: Bound, move: Move?) {
        // Depth-preferred replacement.
        if let existing = tt[slot], existing.key == key, Int(existing.depth) > depth { return }
        tt[slot] = TTEntry(key: key, depth: Int16(depth), score: Int32(score), bound: bound, move: move)
    }

    private func recordCutoff(_ move: Move, ply: Int, depth: Int) {
        // Killers: quiet moves that caused a beta cutoff at this ply.
        if killers[ply][0] != move {
            killers[ply][1] = killers[ply][0]
            killers[ply][0] = move
        }
        history[historyKey(move), default: 0] += depth * depth
    }

    // MARK: - Move ordering

    private func orderMoves(_ moves: [Move], state: GameState, ttMove: Move?, ply: Int) -> [Move] {
        let enemyQueen = state.queenPosition(state.currentPlayer.opponent)
        let k0 = ply < killers.count ? killers[ply][0] : nil
        let k1 = ply < killers.count ? killers[ply][1] : nil
        return moves.sorted { a, b in
            moveScore(a, ttMove: ttMove, enemyQueen: enemyQueen, k0: k0, k1: k1)
                > moveScore(b, ttMove: ttMove, enemyQueen: enemyQueen, k0: k0, k1: k1)
        }
    }

    private func moveScore(_ move: Move, ttMove: Move?, enemyQueen: Hex?,
                           k0: Move?, k1: Move?) -> Int {
        if move == ttMove { return 1_000_000 }
        var score = 0
        // Moves that touch the enemy queen tighten the noose.
        if let q = enemyQueen, let dest = move.destination, q.neighbors.contains(dest) {
            score += 5000
        }
        if move == k0 { score += 900 }
        else if move == k1 { score += 800 }
        score += history[historyKey(move)] ?? 0
        return score
    }

    private func historyKey(_ move: Move) -> Int {
        switch move {
        case .place(let p, let at): return hash2(p.kind.hashValue, hexKey(at))
        case .move(let id, _, let to): return hash2(id.hashValue, hexKey(to))
        case .pillbugMove(_, let id, _, let to): return hash2(id.hashValue ^ 0x55, hexKey(to))
        case .pass: return 0
        }
    }

    private func hash2(_ a: Int, _ b: Int) -> Int { (a &* 31) ^ b }
    private func hexKey(_ h: Hex) -> Int { (h.q &* 1000) &+ h.r }

    // MARK: - Evaluation

    /// Static evaluation from the side-to-move's perspective.
    public func evaluate(_ state: GameState) -> Int {
        HiveAI.staticEval(state, weights: weights)
    }

    public static func staticEval(_ state: GameState, weights w: EvalWeights = .default) -> Int {
        let me = state.currentPlayer
        let enemy = me.opponent
        if let outcome = state.outcome {
            switch outcome {
            case .draw: return 0
            case .win(let c): return c == me ? win : -win
            }
        }

        var score = 0.0

        // 1) Queen pressure. Filling the enemy queen's liberties is the goal;
        //    letting your own fill is the danger. The curve is nonlinear: the
        //    jump from 4→5 is huge (five neighbors = one tempo from defeat).
        let myFill = queenNeighborsFilled(state, me)
        let enemyFill = queenNeighborsFilled(state, enemy)
        score += w.surround[min(enemyFill, 6)] - w.surround[min(myFill, 6)]

        // 2) Pieces adjacent to the enemy queen that are *ours* are worth extra
        //    (they're the ones doing the surrounding and can't easily be shooed).
        score += w.ownQueenAdjacency * Double(queenNeighborsOwnedBy(state, queenOf: enemy, by: me))
        score -= w.ownQueenAdjacency * Double(queenNeighborsOwnedBy(state, queenOf: me, by: enemy))

        // 3) Beetle (or anything) sitting ON a queen pins it hard.
        if let eq = state.queenPosition(enemy), state.board.height(at: eq) > 1,
           state.board.top(at: eq)?.color == me { score += w.beetlePin }
        if let mq = state.queenPosition(me), state.board.height(at: mq) > 1,
           state.board.top(at: mq)?.color == enemy { score -= w.beetlePin }

        // 4) Mobility: pinned (one-hive load-bearing) pieces can't move. Pinning
        //    the opponent while staying free is central to Hive strategy.
        let board = state.board
        let pinned = pinnedPieces(board)
        var myPinned = 0, enemyPinned = 0
        for hex in pinned {
            guard let top = board.top(at: hex) else { continue }
            if top.color == me { myPinned += 1 } else { enemyPinned += 1 }
        }
        score += w.pinnedPiece * Double(enemyPinned - myPinned)

        // 5) Queen safety details: escape routes, total immobility, and a
        //    pillbug bodyguard. A queen that can still run is far from dead.
        let myQueen = state.queenPosition(me)
        let enemyQueen = state.queenPosition(enemy)
        func queenMobility(_ q: Hex?, _ color: PlayerColor) -> (escapes: Int, immobile: Bool) {
            guard let q else { return (0, false) }  // not placed yet: no signal
            let covered = board.top(at: q)?.kind != .queen || board.top(at: q)?.color != color
            if covered || pinned.contains(q) { return (0, true) }
            return (Rules.slideSteps(from: q, board: board.removingTop(at: q)).count, false)
        }
        let mine = queenMobility(myQueen, me)
        let theirs = queenMobility(enemyQueen, enemy)
        score += w.escapeRoute * Double(mine.escapes - theirs.escapes)
        if theirs.immobile { score += w.queenPinned }
        if mine.immobile { score -= w.queenPinned }

        // 6) Free pieces by kind (top of stack and not load-bearing): ants and
        //    beetles are the dangerous movers. Also: free beetles/mosquitoes
        //    already within 2 cells of the enemy queen, and buried pieces.
        var freeScore = 0.0
        var buried = 0.0
        for hex in board.occupiedHexes {
            let stack = board.stack(at: hex)
            guard let top = stack.last else { continue }
            let sign: Double = top.color == me ? 1 : -1
            let isFree = stack.count > 1 || !pinned.contains(hex)
            if isFree && top.kind != .queen {
                switch top.kind {
                case .ant: freeScore += sign * w.freeAnt
                case .beetle, .mosquito:
                    freeScore += sign * w.freeBeetle
                    let target = top.color == me ? enemyQueen : myQueen
                    if let target, hex.distance(to: target) <= 2 {
                        freeScore += sign * w.beetleAdvance
                    }
                default: freeScore += sign * w.freeOther
                }
            }
            if stack.count > 1 {
                for piece in stack.dropLast() where piece.kind != .queen && piece.color != top.color {
                    buried += (piece.color == me ? -1 : 1) * w.coveredPiece
                }
            }
        }
        score += freeScore + buried

        // 7) Placement room: cells where each side may legally drop pieces.
        score += w.placementSpot * Double(placementCells(board, for: me) - placementCells(board, for: enemy))

        // 8) Pillbug bodyguard beside its own queen.
        func pillbugGuards(_ q: Hex?, _ color: PlayerColor) -> Bool {
            guard let q else { return false }
            return q.neighbors.contains { board.top(at: $0)?.kind == .pillbug && board.top(at: $0)?.color == color }
        }
        if pillbugGuards(myQueen, me) { score += w.pillbugGuard }
        if pillbugGuards(enemyQueen, enemy) { score -= w.pillbugGuard }

        // 9) Tempo nudge for the side to move.
        score += w.tempo
        return Int(score.rounded())
    }

    /// Empty cells adjacent to at least one of `color`'s tops and none of the
    /// opponent's — i.e. legal placement targets (mid-game rule).
    static func placementCells(_ board: Board, for color: PlayerColor) -> Int {
        var candidates = Set<Hex>()
        for hex in board.occupiedHexes where board.top(at: hex)?.color == color {
            for n in hex.neighbors where !board.isOccupied(n) {
                candidates.insert(n)
            }
        }
        var count = 0
        for cell in candidates {
            if cell.neighbors.allSatisfy({ board.top(at: $0)?.color != color.opponent }) {
                count += 1
            }
        }
        return count
    }

    private static func queenNeighborsFilled(_ state: GameState, _ color: PlayerColor) -> Int {
        guard let q = state.queenPosition(color) else { return 0 }
        return q.neighbors.filter(state.board.isOccupied).count
    }

    private static func queenNeighborsOwnedBy(_ state: GameState, queenOf: PlayerColor,
                                              by owner: PlayerColor) -> Int {
        guard let q = state.queenPosition(queenOf) else { return 0 }
        return q.neighbors.filter { state.board.top(at: $0)?.color == owner }.count
    }

    // MARK: Articulation points (pinned pieces) — one DFS pass.

    /// Ground-level pieces whose removal would disconnect the hive (and thus
    /// may not move under the one-hive rule). Pieces in a stack of height ≥ 2
    /// are never structurally pinned, so only single-height cells qualify.
    static func pinnedPieces(_ board: Board) -> Set<Hex> {
        let cells = board.occupiedHexes
        guard cells.count > 2 else { return [] }
        var index = [Hex: Int]()
        index.reserveCapacity(cells.count)
        for (i, c) in cells.enumerated() { index[c] = i }

        var disc = [Int](repeating: -1, count: cells.count)
        var low = [Int](repeating: 0, count: cells.count)
        var isArt = [Bool](repeating: false, count: cells.count)
        var timer = 0

        // Iterative DFS (recursion could overflow on long hives).
        var stack: [(node: Int, parent: Int, childIdx: Int)] = []
        func neighbors(of i: Int) -> [Int] {
            cells[i].neighbors.compactMap { index[$0] }
        }

        for start in 0..<cells.count where disc[start] == -1 {
            stack.append((start, -1, 0))
            var rootChildren = 0
            while let frame = stack.last {
                let v = frame.node
                if frame.childIdx == 0 {
                    disc[v] = timer; low[v] = timer; timer += 1
                }
                let adj = neighbors(of: v)
                if frame.childIdx < adj.count {
                    stack[stack.count - 1].childIdx += 1
                    let w = adj[frame.childIdx]
                    if disc[w] == -1 {
                        stack.append((w, v, 0))
                        if frame.parent == -1 { rootChildren += 1 }
                    } else if w != frame.parent {
                        low[v] = min(low[v], disc[w])
                    }
                } else {
                    stack.removeLast()
                    if let parentFrame = stack.last {
                        let p = parentFrame.node
                        low[p] = min(low[p], low[v])
                        if parentFrame.parent != -1 && low[v] >= disc[p] {
                            isArt[p] = true
                        }
                    }
                }
            }
            if rootChildren > 1 { isArt[start] = true }
        }

        var result = Set<Hex>()
        for i in 0..<cells.count where isArt[i] && board.height(at: cells[i]) == 1 {
            result.insert(cells[i])
        }
        return result
    }

    // MARK: - Zobrist hashing (translation-normalized)

    // Random keys: [pieceCode][level][localCell]. Cells are normalized so the
    // hive's bounding box starts at (0,0); translates of a position collide,
    // giving real transposition-table hits. (Rotations/reflections are left
    // for a future optimization.)
    private static let gridSpan = 32  // local coords fit well within this
    private static let maxLevel = 7
    private static let pieceCodes = 16  // 8 kinds × 2 colors
    private static let zobristPieces: [UInt64] = {
        var rng = SplitMix64(seed: 0x9E3779B97F4A7C15)
        let count = pieceCodes * maxLevel * gridSpan * gridSpan
        return (0..<count).map { _ in rng.next() }
    }()
    private static let zobristSide: UInt64 = {
        var rng = SplitMix64(seed: 0xD1B54A32D192ED03)
        return rng.next()
    }()

    private func zobrist(_ state: GameState) -> UInt64 {
        let cells = state.board.occupiedHexes
        guard !cells.isEmpty else {
            return state.currentPlayer == .white ? 0 : Self.zobristSide
        }
        var minQ = Int.max, minR = Int.max
        for c in cells { minQ = min(minQ, c.q); minR = min(minR, c.r) }

        var hash: UInt64 = 0
        for hex in cells {
            let lq = hex.q - minQ
            let lr = hex.r - minR
            guard lq >= 0, lq < Self.gridSpan, lr >= 0, lr < Self.gridSpan else { continue }
            let stack = state.board.stack(at: hex)
            for (level, piece) in stack.enumerated() where level < Self.maxLevel {
                let code = pieceCode(piece)
                let idx = ((code * Self.maxLevel + level) * Self.gridSpan + lq) * Self.gridSpan + lr
                hash ^= Self.zobristPieces[idx]
            }
        }
        if state.currentPlayer == .black { hash ^= Self.zobristSide }
        return hash
    }

    private func pieceCode(_ piece: Piece) -> Int {
        let kindIndex = PieceKind.allCases.firstIndex(of: piece.kind) ?? 0
        return kindIndex * 2 + (piece.color == .white ? 0 : 1)
    }
}

/// Small fast PRNG for generating fixed Zobrist keys (not security-sensitive).
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
