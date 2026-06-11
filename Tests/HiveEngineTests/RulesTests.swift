import XCTest
@testable import HiveEngine

final class RulesTests: XCTestCase {

    func newGame(expansions: Bool = false, starting: PlayerColor = .white) -> GameState {
        GameState(config: GameConfig(useExpansions: expansions), startingPlayer: starting)
    }

    @discardableResult
    func play(_ state: inout GameState, _ move: Move) -> GameState {
        state = try! Rules.apply(move, to: state)
        return state
    }

    func place(_ state: inout GameState, _ kind: PieceKind, _ hex: Hex) {
        let color = state.currentPlayer
        let moves = Rules.legalMoves(state)
        guard let move = moves.first(where: {
            if case .place(let p, let at) = $0 { return p.kind == kind && at == hex }
            return false
        }) else {
            XCTFail("No legal placement of \(kind) at \(hex) for \(color)")
            return
        }
        play(&state, move)
    }

    /// Standard line: wS(0,0) bG(1,0) wQ(-1,0) bQ(2,0), then one more piece
    /// per side at the line's ends: white `kind` at (-2,0), black ant at (3,0).
    /// Leaves white to move with `kind` at the west end of a 6-piece line.
    func lineGame(westEnd kind: PieceKind, expansions: Bool = false) -> GameState {
        var state = newGame(expansions: expansions)
        place(&state, .spider, Hex(0, 0))
        place(&state, .grasshopper, Hex(1, 0))
        place(&state, .queen, Hex(-1, 0))
        place(&state, .queen, Hex(2, 0))
        place(&state, kind, Hex(-2, 0))
        place(&state, .ant, Hex(3, 0))
        return state
    }

    func movements(of pieceID: String, in state: GameState) -> Set<Hex> {
        Set(Rules.legalMovements(state).compactMap { move -> Hex? in
            if case .move(let id, _, let to) = move, id == pieceID { return to }
            return nil
        })
    }

    // MARK: Opening

    func testFirstPlacementIsOrigin() {
        let state = newGame()
        let targets = Set(Rules.legalMoves(state).compactMap(\.destination))
        XCTAssertEqual(targets, [Hex(0, 0)])
    }

    func testQueenCannotOpenAndSecondPlacementTouchesEnemy() {
        var state = newGame()
        let openingKinds = Set(Rules.legalMoves(state).compactMap { move -> PieceKind? in
            if case .place(let p, _) = move { return p.kind }
            return nil
        })
        XCTAssertFalse(openingKinds.contains(.queen))
        place(&state, .ant, Hex(0, 0))
        // Black's first placement: any of the six neighbors (and no queen).
        let targets = Set(Rules.legalMoves(state).compactMap(\.destination))
        XCTAssertEqual(targets, Set(Hex(0, 0).neighbors))
    }

    func testThirdPlacementMustNotTouchEnemy() {
        var state = newGame()
        place(&state, .ant, Hex(0, 0))
        place(&state, .ant, Hex(1, 0))
        let targets = Set(Rules.legalPlacements(state).compactMap(\.destination))
        XCTAssertFalse(targets.isEmpty)
        for t in targets {
            XCTAssertTrue(t.neighbors.contains(Hex(0, 0)), "\(t) must touch own piece")
            XCTAssertFalse(t.neighbors.contains(Hex(1, 0)), "\(t) must not touch enemy")
        }
    }

    func testQueenForcedOnFourthPlacement() {
        var state = newGame()
        place(&state, .ant, Hex(0, 0))
        place(&state, .ant, Hex(1, 0))
        place(&state, .spider, Hex(-1, 0))
        place(&state, .spider, Hex(2, 0))
        place(&state, .grasshopper, Hex(-2, 0))
        place(&state, .grasshopper, Hex(3, 0))
        // White's 4th placement: queen only, and no movements (queen unplaced).
        let moves = Rules.legalMoves(state)
        XCTAssertFalse(moves.isEmpty)
        for move in moves {
            guard case .place(let p, _) = move else {
                XCTFail("Expected placement only, got \(move)")
                continue
            }
            XCTAssertEqual(p.kind, .queen)
        }
    }

    func testNoMovementBeforeQueenPlaced() {
        var state = newGame()
        place(&state, .ant, Hex(0, 0))
        place(&state, .ant, Hex(1, 0))
        XCTAssertTrue(Rules.legalMovements(state).isEmpty)
    }

    // MARK: One Hive + sliding

    func testOneHiveRule() {
        var state = newGame()
        place(&state, .spider, Hex(0, 0))
        place(&state, .spider, Hex(1, 0))
        place(&state, .queen, Hex(-1, 0))
        place(&state, .queen, Hex(2, 0))
        // White spider at (0,0) is interior; moving it would split the hive.
        XCTAssertTrue(movements(of: "wS1", in: state).isEmpty)
        XCTAssertFalse(movements(of: "wQ1", in: state).isEmpty)
    }

    func testQueenSlidesOneStep() {
        var state = newGame()
        place(&state, .spider, Hex(0, 0))
        place(&state, .spider, Hex(1, 0))
        place(&state, .queen, Hex(-1, 0))
        place(&state, .queen, Hex(2, 0))
        // Queen at the west end of the line slides to the two cells flanking
        // its only neighbor.
        XCTAssertEqual(movements(of: "wQ1", in: state), [Hex(-1, 1), Hex(0, -1)])
    }

    func testGrasshopperJumpsOverLine() {
        let state = lineGame(westEnd: .grasshopper)
        // From (-2,0) the only adjacent piece lies east; jump the whole
        // 5-piece line and land on the first empty cell beyond it.
        XCTAssertEqual(movements(of: "wG1", in: state), [Hex(4, 0)])
    }

    func testAntRoamsEntirePerimeter() {
        let state = lineGame(westEnd: .ant)
        let board = state.board
        // Expected: every empty cell adjacent to the hive-without-the-ant,
        // except the ant's own starting cell (a straight line has no gates).
        var expected: Set<Hex> = []
        let remaining = board.removingTop(at: Hex(-2, 0))
        for hex in remaining.occupiedHexes {
            for n in hex.neighbors where !remaining.isOccupied(n) {
                expected.insert(n)
            }
        }
        expected.remove(Hex(-2, 0))
        XCTAssertEqual(movements(of: "wA1", in: state), expected)
    }

    func testSpiderMovesExactlyThree() {
        var state = newGame()
        place(&state, .ant, Hex(0, 0))
        place(&state, .grasshopper, Hex(1, 0))
        place(&state, .queen, Hex(-1, 0))
        place(&state, .queen, Hex(2, 0))
        place(&state, .spider, Hex(-2, 0))
        place(&state, .ant, Hex(3, 0))
        // Spider at the west end walks exactly three cells along either side.
        XCTAssertEqual(movements(of: "wS1", in: state), [Hex(1, -1), Hex(0, 1)])
    }

    func testBeetleClimbsAndStacks() {
        var state = newGame()
        place(&state, .spider, Hex(0, 0))
        place(&state, .grasshopper, Hex(1, 0))
        place(&state, .queen, Hex(-1, 0))
        place(&state, .queen, Hex(2, 0))
        place(&state, .beetle, Hex(0, -1))
        place(&state, .ant, Hex(3, 0))
        // White beetle climbs onto the white spider.
        XCTAssertTrue(movements(of: "wB1", in: state).contains(Hex(0, 0)))
        play(&state, .move(pieceID: "wB1", from: Hex(0, -1), to: Hex(0, 0)))
        XCTAssertEqual(state.board.height(at: Hex(0, 0)), 2)
        XCTAssertEqual(state.board.top(at: Hex(0, 0))?.id, "wB1")
        // The stacked cell counts as white (top piece) for placements.
        XCTAssertEqual(state.board.top(at: Hex(0, 0))?.color, .white)
    }

    // MARK: Win condition

    func testSurroundedQueenLoses() {
        var state = newGame()
        place(&state, .ant, Hex(0, 0))
        var board = state.board
        board.push(Piece(kind: .queen, color: .black, index: 1), at: Hex(1, 0))
        for (i, n) in Hex(1, 0).neighbors.enumerated() where !board.isOccupied(n) {
            board.push(Piece(kind: .ant, color: .white, index: i + 2), at: n)
        }
        state.board = board
        XCTAssertTrue(state.isQueenSurrounded(.black))
        XCTAssertEqual(Rules.computeOutcome(state), .win(.white))
    }

    // MARK: Expansions

    func testLadybugMovesOverHiveAndDown() {
        let state = lineGame(westEnd: .ladybug, expansions: true)
        // From (-2,0): over wQ(-1,0), over wS(0,0), down to an empty neighbor
        // of (0,0).
        XCTAssertEqual(movements(of: "wL1", in: state),
                       [Hex(0, -1), Hex(1, -1), Hex(0, 1), Hex(-1, 1)])
    }

    func testMosquitoCopiesNeighbors() {
        var state = newGame(expansions: true)
        place(&state, .grasshopper, Hex(0, 0))
        place(&state, .spider, Hex(1, 0))
        place(&state, .queen, Hex(-1, 0))
        place(&state, .queen, Hex(2, 0))
        place(&state, .mosquito, Hex(-1, 1))  // touches wQ(-1,0) and wG(0,0)
        place(&state, .ant, Hex(3, 0))
        let targets = movements(of: "wM1", in: state)
        // Copies the grasshopper: jump over (0,0) to (1,-1).
        XCTAssertTrue(targets.contains(Hex(1, -1)), "should jump like adjacent grasshopper")
        // Copies the queen: slide one step to (0,1).
        XCTAssertTrue(targets.contains(Hex(0, 1)), "should slide like adjacent queen")
    }

    func testPillbugThrowsAdjacentPiece() {
        var state = newGame(expansions: true)
        place(&state, .pillbug, Hex(0, 0))
        place(&state, .grasshopper, Hex(1, 0))
        place(&state, .queen, Hex(-1, 0))
        place(&state, .queen, Hex(2, 0))
        // bG(1,0) is load-bearing, so the pillbug may only throw wQ(-1,0).
        let throwsFound = Rules.legalMovements(state).compactMap { move -> (String, Hex)? in
            if case .pillbugMove(_, let pid, _, let to) = move { return (pid, to) }
            return nil
        }
        XCTAssertFalse(throwsFound.isEmpty)
        XCTAssertTrue(throwsFound.allSatisfy { $0.0 == "wQ1" })
        for (_, to) in throwsFound {
            XCTAssertTrue(Hex(0, 0).neighbors.contains(to), "throws land beside the pillbug")
            XCTAssertFalse(state.board.isOccupied(to))
        }
    }

    func testThrownPieceIsImmobileNextTurn() {
        var state = newGame(expansions: true)
        place(&state, .pillbug, Hex(0, 0))
        place(&state, .pillbug, Hex(1, 0))
        place(&state, .queen, Hex(-1, 0))
        place(&state, .queen, Hex(2, 0))
        // White throws own queen to (1,-1), adjacent to black's pillbug.
        play(&state, .pillbugMove(pillbugID: "wP1", pieceID: "wQ1",
                                  from: Hex(-1, 0), to: Hex(1, -1)))
        XCTAssertEqual(state.immobilePieceID, "wQ1")
        // Black may neither move nor throw the just-thrown white queen.
        let blackThrows = Rules.legalMovements(state).compactMap { move -> String? in
            if case .pillbugMove(_, let pid, _, _) = move { return pid }
            return nil
        }
        XCTAssertFalse(blackThrows.contains("wQ1"))
    }

    func testPlacementSetsLastMovedForPillbugProtection() {
        // Official FAQ: a just-placed piece counts as the opponent's most
        // recently moved piece, so a pillbug may not throw it next turn.
        var state = newGame(expansions: true)
        place(&state, .pillbug, Hex(0, 0))
        place(&state, .grasshopper, Hex(1, 0))
        XCTAssertEqual(state.lastMovedPieceID, "bG1")
        place(&state, .queen, Hex(-1, 0))
        XCTAssertEqual(state.lastMovedPieceID, "wQ1")
    }

    // MARK: Engine invariants

    func testLegalMovesNeverEmptyWhileGameRuns() {
        let state = newGame()
        XCTAssertFalse(Rules.legalMoves(state).isEmpty)
    }

    func testFullGameRandomPlayout() {
        // Engine fuzz: play random legal moves; the hive must stay connected.
        for seed in 0..<6 {
            var state = newGame(expansions: seed % 2 == 0)
            var rng = SeededRNG(seed: UInt64(seed) + 1)
            for _ in 0..<120 {
                if state.outcome != nil { break }
                let moves = Rules.legalMoves(state)
                XCTAssertFalse(moves.isEmpty)
                let move = moves[Int(rng.next() % UInt64(moves.count))]
                state = try! Rules.apply(move, to: state)
                if let anyHex = state.board.occupiedHexes.first {
                    var visited: Set<Hex> = [anyHex]
                    var frontier = [anyHex]
                    while let c = frontier.popLast() {
                        for n in c.neighbors where state.board.isOccupied(n) && !visited.contains(n) {
                            visited.insert(n)
                            frontier.append(n)
                        }
                    }
                    XCTAssertEqual(visited.count, state.board.occupiedHexes.count,
                                   "Hive disconnected after \(state.movesPlayed.count) moves (seed \(seed))")
                }
            }
        }
    }

    func testNetMessageRoundTrip() throws {
        let move = Move.move(pieceID: "wA1", from: Hex(0, 0), to: Hex(2, -1))
        let data = try NetCodec.encode(.move(move, turnIndex: 7))
        // 4-byte length prefix, then JSON body.
        let length = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        XCTAssertEqual(length, data.count - 4)
        let decoded = try NetCodec.decodeBody(data.dropFirst(4))
        guard case .move(let m, let idx) = decoded else {
            return XCTFail("Wrong message type")
        }
        XCTAssertEqual(m, move)
        XCTAssertEqual(idx, 7)
    }
}

struct SeededRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 16
    }
}
