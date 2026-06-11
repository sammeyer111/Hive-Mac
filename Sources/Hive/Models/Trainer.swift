import Foundation
import HiveEngine

/// Loads/saves the evolved evaluation weights. The background trainer writes
/// this file; the in-game bot and the analyzer read it at startup, so the AI
/// in the app automatically gets stronger as training progresses.
enum TunedWeights {
    static func dataDir() -> URL {
        if let override = ProcessInfo.processInfo.environment["HIVE_DATA_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HiveP2P", isDirectory: true)
    }

    static var fileURL: URL { dataDir().appendingPathComponent("tuned-weights.json") }

    static func load() -> EvalWeights {
        guard let data = try? Data(contentsOf: fileURL),
              let weights = try? JSONDecoder().decode(EvalWeights.self, from: data) else {
            return .default
        }
        return weights
    }

    static func save(_ weights: EvalWeights) {
        try? FileManager.default.createDirectory(at: dataDir(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(weights) {
            try? data.write(to: fileURL)
        }
    }
}

/// `Hive --train`: evolutionary self-play tuning, the classic way game engines
/// are strengthened without any external service. Each round mutates the
/// champion's evaluation weights and plays a candidate-vs-champion match
/// (paired games: same random opening, colors swapped, so neither side gets
/// lucky openings). If the candidate clearly wins, it becomes the champion
/// and is saved — the app picks it up on next launch. Runs until killed.
///
/// Flags: --rounds N (default 0 = forever), --games N per match (default 10),
///        --movetime MS per move (default 150).
enum Trainer {

    static func runAndExit() {
        setvbuf(stdout, nil, _IOLBF, 0)  // line-buffered so logs stream to file

        let args = CommandLine.arguments
        func intArg(_ flag: String, _ fallback: Int) -> Int {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count,
                  let v = Int(args[i + 1]) else { return fallback }
            return v
        }
        let rounds = intArg("--rounds", 0)
        var games = max(2, intArg("--games", 10))
        if games % 2 == 1 { games += 1 }  // paired openings need an even count
        let moveTime = Double(intArg("--movetime", 150)) / 1000.0
        let cores = ProcessInfo.processInfo.activeProcessorCount
        // Default: leave one core for the OS; --threads overrides.
        let threads = max(1, intArg("--threads", max(1, cores - 1)))
        let watching = args.contains("--watch")
        // Adopt only on a clear win: ≥60% of the points and strictly > half.
        let adoptThreshold = max(Double(games) * 0.6, Double(games) / 2 + 0.5)

        var champion = TunedWeights.load()
        var rng = SystemRandomNumberGenerator()
        var round = 0
        var adoptions = 0

        log("trainer: starting — \(games) games/round, \(Int(moveTime * 1000))ms/move, " +
            "\(threads) threads (of \(cores) cores), adopt at ≥\(adoptThreshold) pts")
        log("trainer: weights file \(TunedWeights.fileURL.path)")
        log("trainer: champion = \(describe(champion))")

        while rounds == 0 || round < rounds {
            round += 1
            let candidate = mutate(champion, rng: &rng)
            // Watch mode: play one exhibition game (candidate White vs champion
            // Black) rendered move-by-move before the headless scoring match.
            if watching {
                watchExhibition(round: round, candidate: candidate, champion: champion,
                                moveTime: moveTime, rng: &rng)
            }
            let start = Date()
            let points = match(candidate: candidate, champion: champion,
                               games: games, moveTime: moveTime, threads: threads, rng: &rng)
            let mins = Date().timeIntervalSince(start) / 60
            if points >= adoptThreshold {
                champion = candidate
                adoptions += 1
                TunedWeights.save(champion)
                log(String(format: "round %d: %.1f/%d pts in %.1fm — ADOPTED (#%d): %@",
                           round, points, games, mins, adoptions, describe(champion)))
                log("pruning: \(prunedReport(champion))")
            } else {
                log(String(format: "round %d: %.1f/%d pts in %.1fm — kept champion (adoptions: %d)",
                           round, points, games, mins, adoptions))
                if round % 25 == 0 { log("pruning: \(prunedReport(champion))") }
            }
        }
        log("trainer: done — \(round) rounds, \(adoptions) adoptions")
        exit(0)
    }

    // MARK: Mutation

    /// Every tunable scalar attribute: name, accessor, allowed range. The
    /// surround curve is handled separately (it must stay escalating).
    static let tunables: [(name: String, path: WritableKeyPath<EvalWeights, Double>, range: ClosedRange<Double>)] = [
        ("adjacency", \.ownQueenAdjacency, 0...60),
        ("beetlePin", \.beetlePin, 0...300),
        ("pinned", \.pinnedPiece, 0...60),
        ("tempo", \.tempo, 0...30),
        ("escape", \.escapeRoute, 0...80),
        ("queenPinned", \.queenPinned, 0...300),
        ("freeAnt", \.freeAnt, 0...40),
        ("freeBeetle", \.freeBeetle, 0...40),
        ("freeOther", \.freeOther, 0...20),
        ("beetleAdv", \.beetleAdvance, 0...80),
        ("placement", \.placementSpot, 0...20),
        ("covered", \.coveredPiece, 0...60),
        ("pillbugGrd", \.pillbugGuard, 0...60),
    ]

    private static func mutate(_ weights: EvalWeights, rng: inout SystemRandomNumberGenerator) -> EvalWeights {
        var w = weights
        // Perturb 1–3 randomly chosen parameters: log-normal scaling plus a
        // small additive jitter so values can both escape and reach zero.
        let count = Int.random(in: 1...3, using: &rng)
        for _ in 0..<count {
            let factor = exp(gaussian(&rng) * 0.22)
            if Int.random(in: 0..<(tunables.count + 2), using: &rng) < 2 {
                // Surround curve step (indices 1...5; 0 stays 0, 6 is terminal).
                let i = Int.random(in: 1...5, using: &rng)
                w.surround[i] = max(1, w.surround[i] * factor + gaussian(&rng))
                let tail = w.surround[1...5].sorted()
                w.surround.replaceSubrange(1...5, with: tail)
            } else {
                let t = tunables[Int.random(in: 0..<tunables.count, using: &rng)]
                let jitter = gaussian(&rng) * max(0.3, EvalWeights.default[keyPath: t.path] * 0.05)
                w[keyPath: t.path] = clamp(w[keyPath: t.path] * factor + jitter, t.range.lowerBound, t.range.upperBound)
            }
        }
        return w
    }

    /// Attributes the trainer has driven to (near) zero — effectively removed
    /// from the AI's judgment. Logged so dead attributes are visible.
    private static func prunedReport(_ w: EvalWeights) -> String {
        let dead = tunables.filter { w[keyPath: $0.path] < max(0.5, EvalWeights.default[keyPath: $0.path] * 0.10) }
        guard !dead.isEmpty else { return "no attributes pruned (all carrying weight)" }
        let list = dead.map { String(format: "%@=%.2f", $0.name, w[keyPath: $0.path]) }.joined(separator: ", ")
        return "effectively pruned (≈0): \(list)"
    }

    // MARK: Match play

    /// One scheduled game: a fixed opening, with the candidate on a chosen color.
    private struct GameSpec {
        var config: GameConfig
        var opening: [Move]
        var candidateIsWhite: Bool
    }

    /// Candidate's points over `games` games (win 1, draw 0.5). Games come in
    /// pairs sharing a random opening with colors swapped; pairs alternate
    /// between the classic and full piece sets. All games run concurrently
    /// across `threads` worker threads — each game builds its own engines, so
    /// they're fully independent.
    private static func match(candidate: EvalWeights, champion: EvalWeights,
                              games: Int, moveTime: Double, threads: Int,
                              rng: inout SystemRandomNumberGenerator) -> Double {
        // Build the full game list up front (openings need the seeded RNG,
        // which isn't thread-safe — so generate serially here).
        var specs: [GameSpec] = []
        for pair in 0..<(games / 2) {
            let config = GameConfig(useExpansions: pair % 2 == 0)
            let opening = randomOpening(config: config, plies: 2, rng: &rng)
            specs.append(GameSpec(config: config, opening: opening, candidateIsWhite: true))
            specs.append(GameSpec(config: config, opening: opening, candidateIsWhite: false))
        }

        let lock = NSLock()
        var points = 0.0
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(1, threads)

        for spec in specs {
            queue.addOperation {
                let outcome = play(
                    config: spec.config, opening: spec.opening,
                    white: spec.candidateIsWhite ? candidate : champion,
                    black: spec.candidateIsWhite ? champion : candidate,
                    moveTime: moveTime)
                let p: Double
                switch outcome {
                case .win(.white): p = spec.candidateIsWhite ? 1 : 0
                case .win(.black): p = spec.candidateIsWhite ? 0 : 1
                default: p = 0.5  // draw or ply-capped
                }
                lock.lock(); points += p; lock.unlock()
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return points
    }

    // MARK: Watching (terminal exhibition game)

    /// Plays one candidate(White)-vs-champion(Black) game, printing the board
    /// after every move so you can watch the duel live in the terminal.
    private static func watchExhibition(round: Int, candidate: EvalWeights, champion: EvalWeights,
                                        moveTime: Double, rng: inout SystemRandomNumberGenerator) {
        let config = GameConfig(useExpansions: round % 2 == 0)
        var state = GameState(config: config, startingPlayer: .white)
        let whiteEngine = HiveAI(sizeMB: 24, weights: candidate)
        let blackEngine = HiveAI(sizeMB: 24, weights: champion)
        let limits = HiveAI.Limits(maxDepth: 30, maxTime: moveTime)

        print("\n=== round \(round) exhibition — White: candidate  Black: champion " +
              "(\(config.useExpansions ? "Full" : "Classic")) ===")
        var plies = 0
        while state.outcome == nil && plies < 140 {
            let mover = state.currentPlayer
            guard let move = (mover == .white ? whiteEngine : blackEngine).bestMove(state, limits: limits) else { break }
            let notation = Notation.describe(move, before: state)
            guard let next = Rules.applyUnchecked(move, to: state) else { break }
            state = next
            plies += 1
            print("\nmove \(plies): \(mover == .white ? "White(cand)" : "Black(champ)") plays \(notation)")
            print(asciiBoard(state))
        }
        switch state.outcome {
        case .win(.white): print(">>> candidate (White) WINS the exhibition\n")
        case .win(.black): print(">>> champion (Black) wins the exhibition\n")
        default: print(">>> exhibition drawn\n")
        }
    }

    /// Compact ASCII rendering of the board. Tokens are color+kind (e.g. "wA",
    /// "bQ"); only the top of each stack is shown. Rows are staggered to give
    /// the hex grid its offset look.
    static func asciiBoard(_ state: GameState) -> String {
        let cells = state.board.occupiedHexes
        guard !cells.isEmpty else { return "(empty)" }
        // Screen coords: x = 2q + r (stagger), y = r.
        func sx(_ h: Hex) -> Int { 2 * h.q + h.r }
        let minX = cells.map(sx).min()!, maxX = cells.map(sx).max()!
        let minY = cells.map(\.r).min()!, maxY = cells.map(\.r).max()!
        let width = maxX - minX + 1
        var grid = Array(repeating: Array(repeating: " . ", count: width),
                         count: maxY - minY + 1)
        for hex in cells {
            guard let top = state.board.top(at: hex) else { continue }
            let token = "\(top.color == .white ? "w" : "b")\(top.kind.letter)"
            let height = state.board.height(at: hex)
            grid[hex.r - minY][sx(hex) - minX] = height > 1 ? "\(token)\(height)" : " \(token)"
        }
        return grid.map { $0.joined() }.joined(separator: "\n")
    }

    private static func randomOpening(config: GameConfig, plies: Int,
                                      rng: inout SystemRandomNumberGenerator) -> [Move] {
        var state = GameState(config: config, startingPlayer: .white)
        var moves: [Move] = []
        for _ in 0..<plies {
            guard let move = Rules.legalMoves(state).randomElement(using: &rng),
                  let next = Rules.applyUnchecked(move, to: state) else { break }
            moves.append(move)
            state = next
        }
        return moves
    }

    private static func play(config: GameConfig, opening: [Move],
                             white: EvalWeights, black: EvalWeights,
                             moveTime: Double) -> Outcome? {
        var state = GameState(config: config, startingPlayer: .white)
        for move in opening {
            guard let next = Rules.applyUnchecked(move, to: state) else { break }
            state = next
        }
        // Small tables keep memory flat across thousands of games.
        let whiteEngine = HiveAI(sizeMB: 16, weights: white)
        let blackEngine = HiveAI(sizeMB: 16, weights: black)
        let limits = HiveAI.Limits(maxDepth: 30, maxTime: moveTime)

        var consecutivePasses = 0
        var plies = opening.count
        while state.outcome == nil && plies < 140 {
            let engine = state.currentPlayer == .white ? whiteEngine : blackEngine
            guard let move = engine.bestMove(state, limits: limits),
                  let next = try? Rules.apply(move, to: state) else { break }
            if case .pass = move { consecutivePasses += 1 } else { consecutivePasses = 0 }
            if consecutivePasses >= 4 { return nil }  // locked position: call it a draw
            state = next
            plies += 1
        }
        return state.outcome
    }

    // MARK: Utilities

    private static func gaussian(_ rng: inout SystemRandomNumberGenerator) -> Double {
        let u1 = Double.random(in: 1e-9..<1, using: &rng)
        let u2 = Double.random(in: 0..<1, using: &rng)
        return (-2 * Foundation.log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }

    private static func describe(_ w: EvalWeights) -> String {
        let surround = w.surround.map { String(format: "%.0f", $0) }.joined(separator: ",")
        let scalars = tunables
            .map { String(format: "%@ %.1f", $0.name, w[keyPath: $0.path]) }
            .joined(separator: " ")
        return "surround[\(surround)] \(scalars)"
    }

    private static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("[\(stamp)] \(message)")
    }
}
