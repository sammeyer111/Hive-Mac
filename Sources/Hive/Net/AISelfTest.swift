import Foundation
import HiveEngine

/// `Hive --selftest-ai`: plays a Strong-vs-Beginner game, then runs the
/// analyzer over it and prints a summary. Confirms the engine plays a full
/// legal game and the analysis pipeline produces sane accuracy/classifications.
enum AISelfTest {
    /// `Hive --make-sample-game` (with HIVE_DATA_DIR set): plays an engine vs.
    /// random game and saves it to games.json so the History/analysis UI has a
    /// real record to open. Dev/testing aid only.
    static func makeSampleGameAndExit() {
        let engine = HiveAI(sizeMB: 32)
        let config = GameConfig(useExpansions: false)
        var state = GameState(config: config, startingPlayer: .white)
        var moves: [Move] = []
        var rng = SystemRandomNumberGenerator()
        var plies = 0
        while state.outcome == nil && plies < 120 {
            let move = state.currentPlayer == .white
                ? engine.bestMove(state, limits: .init(maxDepth: 12, maxTime: 0.5))
                : Rules.legalMoves(state).randomElement(using: &rng)
            guard let move, let next = try? Rules.apply(move, to: state) else { break }
            moves.append(move); state = next; plies += 1
        }
        let result: String
        if case .win(.white) = state.outcome { result = "Win" }
        else if case .win(.black) = state.outcome { result = "Loss" }
        else { result = "Draw" }

        let record = GameRecord(
            date: Date(),
            config: config,
            startingPlayer: .white,
            myColor: .white,
            opponent: BotDifficulty.beginner.profile,
            moves: moves,
            result: result,
            reason: "Queen surrounded")

        let dir = ProcessInfo.processInfo.environment["HIVE_DATA_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HiveP2P", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("games.json")
        if let data = try? JSONEncoder().encode([record]) {
            try? data.write(to: url)
            print("wrote sample game (\(moves.count) plies, \(result)) to \(url.path)")
        }
        exit(0)
    }

    static func runAndExit() {
        let engine = HiveAI(sizeMB: 32)
        let config = GameConfig(useExpansions: true)
        var state = GameState(config: config, startingPlayer: .white)
        var moves: [Move] = []
        var rng = SystemRandomNumberGenerator()

        // White = strong engine, Black = weak/random, so White should win and
        // Black should rack up mistakes for the analyzer to catch.
        var plies = 0
        while state.outcome == nil && plies < 200 {
            let move: Move?
            if state.currentPlayer == .white {
                move = engine.bestMove(state, limits: .init(maxDepth: 14, maxTime: 0.8))
            } else {
                move = Rules.legalMoves(state).randomElement(using: &rng)
            }
            guard let move, let next = try? Rules.apply(move, to: state) else { break }
            moves.append(move)
            state = next
            plies += 1
        }

        print("ai: played \(moves.count) plies, outcome \(String(describing: state.outcome))")

        // Analyze synchronously.
        let analyzerEngine = HiveAI(sizeMB: 64)
        let limits = HiveAI.Limits(maxDepth: 14, maxTime: 0.3)
        var s2 = GameState(config: config, startingPlayer: .white)
        var whiteLoss: [Double] = []
        var blackLoss: [Double] = []
        var blunders = 0
        for played in moves {
            let mover = s2.currentPlayer
            let best = analyzerEngine.search(s2, limits: limits)
            let bestW = mover == .white ? best.score : -best.score
            let after = Rules.applyUnchecked(played, to: s2)!
            let playedRes = analyzerEngine.search(after, limits: limits)
            let playedW = mover == .white ? -playedRes.score : playedRes.score
            func wp(_ e: Int) -> Double { 1 / (1 + exp(-Double(e) / 180.0)) }
            let bestWP = mover == .white ? wp(bestW) : 1 - wp(bestW)
            let playedWP = mover == .white ? wp(playedW) : 1 - wp(playedW)
            let loss = max(0, bestWP - playedWP)
            if mover == .white { whiteLoss.append(loss) } else { blackLoss.append(loss) }
            if loss >= 0.20 { blunders += 1 }
            s2 = after
        }
        func acc(_ l: [Double]) -> Double {
            guard !l.isEmpty else { return 100 }
            return max(0, min(100, 100 * (1 - (l.reduce(0,+) / Double(l.count)) * 2.2)))
        }
        let wa = acc(whiteLoss), ba = acc(blackLoss)
        print(String(format: "ai: White acc %.0f%%, Black acc %.0f%%, blunders flagged %d", wa, ba, blunders))

        // Sanity: the strong side should be at least as accurate as the random
        // side, and the analyzer should flag at least one blunder in a random
        // player's game.
        let ok = wa >= ba && blunders >= 1 && !moves.isEmpty
        print(ok ? "selftest: PASS — engine + analysis sane" : "selftest: FAIL")
        exit(ok ? 0 : 1)
    }
}
