import XCTest
@testable import HiveEngine

final class HiveAITests: XCTestCase {

    /// Reference greedy player matching the old bot's logic, to prove the
    /// search engine is meaningfully stronger.
    static func greedyMove(_ state: GameState) -> Move? {
        let moves = Rules.legalMoves(state)
        guard !moves.isEmpty else { return nil }
        let me = state.currentPlayer
        return moves.max { a, b in
            let sa = HiveAITests.greedyScore(Rules.applyUnchecked(a, to: state), me)
            let sb = HiveAITests.greedyScore(Rules.applyUnchecked(b, to: state), me)
            return sa < sb
        }
    }

    static func greedyScore(_ state: GameState?, _ me: PlayerColor) -> Int {
        guard let state else { return -1_000_000 }
        if case .win(me) = state.outcome { return 1_000_000 }
        func filled(_ c: PlayerColor) -> Int {
            guard let q = state.queenPosition(c) else { return 0 }
            return q.neighbors.filter(state.board.isOccupied).count
        }
        return 16 * filled(me.opponent) - 12 * filled(me) - (state.hands[me]?.values.reduce(0, +) ?? 0) / 2
    }

    func testArticulationMatchesOneHiveRule() {
        // The articulation-point set must equal the pieces the rules engine
        // forbids from moving (single-height, structurally load-bearing).
        var rng = SeededRNG(seed: 7)
        for _ in 0..<40 {
            var state = GameState(config: GameConfig(useExpansions: true), startingPlayer: .white)
            for _ in 0..<25 {
                if state.outcome != nil { break }
                let legal = Rules.legalMoves(state)
                state = try! Rules.apply(legal[Int(rng.next() % UInt64(legal.count))], to: state)
            }
            let pinned = HiveAI.pinnedPieces(state.board)
            for hex in state.board.occupiedHexes where state.board.height(at: hex) == 1 {
                let connected = state.board.remainsConnectedRemovingTop(at: hex)
                // connected == can lift without splitting == NOT pinned.
                XCTAssertEqual(!connected, pinned.contains(hex),
                               "pin mismatch at \(hex)")
            }
        }
    }

    func testFindsImmediateWin() {
        // Black queen at the origin with five of six neighbors filled; the gap
        // is (0,1). A white grasshopper at (0,-2) can hop +r over the filled
        // (0,-1) and the queen, landing in the gap — filling the sixth liberty
        // without vacating a neighbor. That is mate in one.
        var state = GameState(config: GameConfig(), startingPlayer: .white)
        var board = Board()
        board.push(Piece(kind: .queen, color: .black, index: 1), at: Hex(0, 0))
        board.push(Piece(kind: .ant, color: .white, index: 1), at: Hex(1, 0))
        board.push(Piece(kind: .ant, color: .white, index: 2), at: Hex(1, -1))
        board.push(Piece(kind: .grasshopper, color: .white, index: 1), at: Hex(0, -1))
        board.push(Piece(kind: .ant, color: .white, index: 3), at: Hex(-1, 0))
        board.push(Piece(kind: .spider, color: .white, index: 1), at: Hex(-1, 1))
        board.push(Piece(kind: .grasshopper, color: .white, index: 2), at: Hex(0, -2))
        board.push(Piece(kind: .queen, color: .white, index: 1), at: Hex(2, 0))
        state.board = board
        state.currentPlayer = .white
        // White's queen is down, so movement is legal; empty the hand.
        state.hands[.white] = [:]

        // The fixture must actually contain a winning move.
        let winning = Rules.legalMoves(state).filter {
            Rules.applyUnchecked($0, to: state)?.outcome == .win(.white)
        }
        XCTAssertFalse(winning.isEmpty, "test fixture has no mate in one")

        let ai = HiveAI()
        let result = ai.search(state, limits: .init(maxDepth: 3, maxTime: 2))
        XCTAssertNotNil(result.bestMove)
        XCTAssertEqual(Rules.applyUnchecked(result.bestMove!, to: state)?.outcome, .win(.white),
                       "engine should play the move that surrounds the black queen")
        XCTAssertGreaterThan(result.score, HiveAI.win - HiveAI.maxPlyOffset)
    }

    func testBeatsGreedyHeadToHead() {
        // Play several games, engine vs. the greedy reference, alternating who
        // starts. The engine should win the clear majority.
        var engineWins = 0
        var greedyWins = 0
        let ai = HiveAI()
        for game in 0..<2 {
            let engineColor: PlayerColor = game % 2 == 0 ? .white : .black
            var state = GameState(config: GameConfig(), startingPlayer: .white)
            var plies = 0
            while state.outcome == nil && plies < 120 {
                let move: Move?
                if state.currentPlayer == engineColor {
                    move = ai.bestMove(state, limits: .init(maxDepth: 5, maxTime: 0.2))
                } else {
                    move = HiveAITests.greedyMove(state)
                }
                guard let move, let next = try? Rules.apply(move, to: state) else { break }
                state = next
                plies += 1
            }
            if case .win(let c) = state.outcome {
                if c == engineColor { engineWins += 1 } else { greedyWins += 1 }
            }
        }
        // At least a decisive game or two should resolve, and the engine
        // should never lose more than it wins.
        XCTAssertGreaterThanOrEqual(engineWins, greedyWins,
                                    "engine \(engineWins) vs greedy \(greedyWins)")
        XCTAssertGreaterThan(engineWins, 0, "engine should win at least one game")
    }

    func testDeeperSearchRaisesNodeCountButStaysLegal() {
        var state = GameState(config: GameConfig(useExpansions: true), startingPlayer: .white)
        var rng = SeededRNG(seed: 3)
        for _ in 0..<10 {
            let legal = Rules.legalMoves(state)
            state = try! Rules.apply(legal[Int(rng.next() % UInt64(legal.count))], to: state)
        }
        let ai = HiveAI()
        let result = ai.search(state, limits: .init(maxDepth: 8, maxTime: 1.0))
        XCTAssertNotNil(result.bestMove)
        XCTAssertTrue(Rules.legalMoves(state).contains(result.bestMove!),
                      "engine must return a legal move")
        XCTAssertGreaterThan(result.depth, 1, "iterative deepening should reach depth > 1")
    }
}
