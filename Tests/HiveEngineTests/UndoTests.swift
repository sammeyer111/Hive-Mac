import XCTest
@testable import HiveEngine

/// `Rules.replay` is the backbone of the take-back feature: every undo rebuilds
/// the position from a move prefix rather than inverting moves.
final class UndoTests: XCTestCase {

    /// Plays a short opening, snapshotting after every move, then checks that
    /// replaying each prefix reproduces the corresponding snapshot exactly.
    func testReplayPrefixReproducesEveryPriorState() {
        let config = GameConfig(useExpansions: false)
        let start: PlayerColor = .white
        var state = GameState(config: config, startingPlayer: start)
        var snapshots = [state]

        // Drive a legal opening by always taking a deterministic legal move.
        for _ in 0..<10 {
            let moves = Rules.legalMoves(state)
            guard let move = moves.first(where: { if case .place = $0 { return true } else { return false } })
                    ?? moves.first, state.outcome == nil else { break }
            state = try! Rules.apply(move, to: state)
            snapshots.append(state)
        }

        XCTAssertGreaterThan(snapshots.count, 3, "opening should have produced several moves")
        let full = state.movesPlayed

        for k in 0..<snapshots.count {
            let rebuilt = Rules.replay(full.prefix(k), config: config, startingPlayer: start)
            let expected = snapshots[k]
            XCTAssertEqual(rebuilt.movesPlayed, expected.movesPlayed, "moves mismatch at prefix \(k)")
            XCTAssertEqual(rebuilt.currentPlayer, expected.currentPlayer, "turn mismatch at prefix \(k)")
            XCTAssertEqual(rebuilt.outcome, expected.outcome, "outcome mismatch at prefix \(k)")
            XCTAssertEqual(rebuilt.hands, expected.hands, "hands mismatch at prefix \(k)")
            assertSameBoard(rebuilt.board, expected.board, prefix: k)
        }
    }

    /// Replaying zero moves is just the initial position.
    func testReplayEmptyIsInitialState() {
        let config = GameConfig(useExpansions: true)
        let rebuilt = Rules.replay([Move](), config: config, startingPlayer: .black)
        XCTAssertTrue(rebuilt.movesPlayed.isEmpty)
        XCTAssertEqual(rebuilt.currentPlayer, .black)
        XCTAssertNil(rebuilt.outcome)
    }

    private func assertSameBoard(_ a: Board, _ b: Board, prefix: Int) {
        let hexes = Set(a.cells.keys).union(b.cells.keys)
        for hex in hexes {
            let sa = a.stack(at: hex).map(\.id)
            let sb = b.stack(at: hex).map(\.id)
            XCTAssertEqual(sa, sb, "stack at \(hex) mismatch at prefix \(prefix)")
        }
    }
}
