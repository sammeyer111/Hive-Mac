import XCTest
@testable import HiveEngine

final class NotationTests: XCTestCase {

    func testOpeningAndReferences() {
        var state = GameState(config: GameConfig(), startingPlayer: .white)

        // Opening placement: bare name.
        let open = Move.place(piece: Piece(kind: .spider, color: .white, index: 1), at: Hex(0, 0))
        XCTAssertEqual(Notation.describe(open, before: state), "wS1")
        state = try! Rules.apply(open, to: state)

        // East of wS1 → marker after the name.
        let second = Move.place(piece: Piece(kind: .grasshopper, color: .black, index: 1), at: Hex(1, 0))
        XCTAssertEqual(Notation.describe(second, before: state), "bG1 wS1-")
        state = try! Rules.apply(second, to: state)

        // West of wS1 → marker before the name; queen drops its index.
        let third = Move.place(piece: Piece(kind: .queen, color: .white, index: 1), at: Hex(-1, 0))
        XCTAssertEqual(Notation.describe(third, before: state), "wQ -wS1")
    }

    func testClimbAndPass() {
        var state = GameState(config: GameConfig(), startingPlayer: .white)
        state = try! Rules.apply(.place(piece: Piece(kind: .spider, color: .white, index: 1), at: Hex(0, 0)), to: state)
        state = try! Rules.apply(.place(piece: Piece(kind: .grasshopper, color: .black, index: 1), at: Hex(1, 0)), to: state)
        state = try! Rules.apply(.place(piece: Piece(kind: .queen, color: .white, index: 1), at: Hex(-1, 0)), to: state)
        state = try! Rules.apply(.place(piece: Piece(kind: .queen, color: .black, index: 1), at: Hex(2, 0)), to: state)
        state = try! Rules.apply(.place(piece: Piece(kind: .beetle, color: .white, index: 1), at: Hex(0, -1)), to: state)
        state = try! Rules.apply(.place(piece: Piece(kind: .ant, color: .black, index: 1), at: Hex(3, 0)), to: state)

        // Beetle climbing onto the spider names the piece climbed onto.
        let climb = Move.move(pieceID: "wB1", from: Hex(0, -1), to: Hex(0, 0))
        XCTAssertEqual(Notation.describe(climb, before: state), "wB1 wS1")

        XCTAssertEqual(Notation.describe(.pass, before: state), "pass")
    }

    func testListReplaysWholeGame() {
        var state = GameState(config: GameConfig(), startingPlayer: .white)
        var moves: [Move] = []
        var rng = SeededRNG(seed: 42)
        for _ in 0..<30 {
            if state.outcome != nil { break }
            let legal = Rules.legalMoves(state)
            let move = legal[Int(rng.next() % UInt64(legal.count))]
            moves.append(move)
            state = try! Rules.apply(move, to: state)
        }
        let notations = Notation.list(moves: moves, config: GameConfig(), startingPlayer: .white)
        XCTAssertEqual(notations.count, moves.count)
        XCTAssertFalse(notations.contains(""))
    }
}
