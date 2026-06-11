import Foundation
import HiveEngine

/// chess.com-style classification of a played move, by how much eval it gave up
/// versus the engine's best at that position (loss measured in win-probability).
enum MoveClass: String, Codable {
    case best, good, inaccuracy, mistake, blunder, forced

    var label: String {
        switch self {
        case .best: return "Best"
        case .good: return "Good"
        case .inaccuracy: return "Inaccuracy"
        case .mistake: return "Mistake"
        case .blunder: return "Blunder"
        case .forced: return "Forced"
        }
    }

    var symbol: String {
        switch self {
        case .best: return "star.fill"
        case .good: return "checkmark"
        case .inaccuracy: return "exclamationmark"
        case .mistake: return "exclamationmark.2"
        case .blunder: return "xmark.octagon.fill"
        case .forced: return "lock.fill"
        }
    }

    var colorHex: String {
        switch self {
        case .best: return "43A047"
        case .good: return "7CB342"
        case .inaccuracy: return "FBC02D"
        case .mistake: return "FB8C00"
        case .blunder: return "E53935"
        case .forced: return "9E9E9E"
        }
    }
}

/// Per-ply analysis of one played move.
struct PlyAnalysis: Codable, Equatable {
    var mover: PlayerColor
    /// Engine eval *before* the move, from White's perspective (centi-units).
    var evalBefore: Int
    /// Engine eval *after* the played move, from White's perspective.
    var evalAfter: Int
    /// Eval if the engine's best move had been played, White's perspective.
    var bestEval: Int
    var playedNotation: String
    var bestNotation: String
    var bestMove: Move
    var classification: MoveClass
    /// True if the played move was the engine's choice.
    var wasBest: Bool
}

/// Analysis of a whole game.
struct GameAnalysis: Codable, Equatable {
    var plies: [PlyAnalysis]
    var whiteAccuracy: Double
    var blackAccuracy: Double

    /// Eval after each position, White's perspective, length = plies + 1
    /// (index 0 is the start). For the eval graph.
    var evalTimeline: [Int]
}

/// Runs the engine over a finished game off the main thread, producing a
/// GameAnalysis. Progress is reported as a fraction in [0, 1].
@MainActor
final class GameAnalyzer: ObservableObject {
    @Published var progress: Double = 0
    @Published var analysis: GameAnalysis?
    @Published var running = false

    private var task: Task<Void, Never>?

    /// Win-probability (0...1) for White from a centi-unit eval. A logistic
    /// curve scaled so a couple hundred units is a meaningful edge — mirrors
    /// how chess GUIs turn centipawns into a win bar.
    nonisolated static func winProb(_ eval: Int) -> Double {
        if eval >= HiveAI.win - HiveAI.maxPlyOffset { return 1 }
        if eval <= -(HiveAI.win - HiveAI.maxPlyOffset) { return 0 }
        return 1 / (1 + exp(-Double(eval) / 180.0))
    }

    nonisolated static func classify(lossWinProb loss: Double, alternativesCount: Int) -> MoveClass {
        if alternativesCount <= 1 { return .forced }
        switch loss {
        case ..<0.02: return .best
        case ..<0.06: return .good
        case ..<0.12: return .inaccuracy
        case ..<0.20: return .mistake
        default: return .blunder
        }
    }

    func analyze(record: GameRecord, secondsPerMove: Double) {
        cancel()
        running = true
        progress = 0
        let moves = record.moves
        let config = record.config
        let starting = record.startingPlayer

        task = Task {
            let result = await Self.run(
                moves: moves, config: config, starting: starting,
                secondsPerMove: secondsPerMove,
                onProgress: { @MainActor fraction in self.progress = fraction })
            await MainActor.run {
                self.analysis = result
                self.running = false
                self.progress = 1
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        running = false
    }

    private static func run(moves: [Move], config: GameConfig, starting: PlayerColor,
                            secondsPerMove: Double,
                            onProgress: @escaping @MainActor (Double) -> Void) async -> GameAnalysis {
        await Task.detached(priority: .userInitiated) {
            let engine = HiveAI(sizeMB: 64, weights: TunedWeights.load())
            let limits = HiveAI.Limits(maxDepth: 18, maxTime: secondsPerMove)

            var state = GameState(config: config, startingPlayer: starting)
            var plies: [PlyAnalysis] = []
            var timeline: [Int] = [whitePerspective(HiveAI.staticEval(state), state.currentPlayer)]
            var lossByColor: [PlayerColor: [Double]] = [.white: [], .black: []]

            for (i, played) in moves.enumerated() {
                if Task.isCancelled { break }
                let mover = state.currentPlayer
                let legal = Rules.legalMoves(state)

                // Engine's view of this position.
                let result = engine.search(state, limits: limits)
                let bestMove = result.bestMove ?? played
                // result.score is from the mover's perspective.
                let bestEvalWhite = whitePerspective(result.score, mover)

                // Eval after the move actually played.
                let afterPlayed = Rules.applyUnchecked(played, to: state) ?? state
                let evalAfterWhite: Int
                if let outcome = afterPlayed.outcome {
                    // A game-ending move: use the terminal value, not a search
                    // (search on a finished position has no legal moves → score 0,
                    // which would wrongly brand a winning move a blunder).
                    switch outcome {
                    case .win(let c): evalAfterWhite = c == .white ? HiveAI.win : -HiveAI.win
                    case .draw: evalAfterWhite = 0
                    }
                } else {
                    let playedResult = engine.search(afterPlayed, limits: limits)
                    // playedResult.score is from the opponent's perspective (their move next).
                    evalAfterWhite = whitePerspective(-playedResult.score, mover)
                }

                let evalBeforeWhite = timeline.last ?? 0

                // Win-prob lost by the mover.
                let bestWP = winProbForMover(bestEvalWhite, mover: mover)
                let playedWP = winProbForMover(evalAfterWhite, mover: mover)
                let loss = max(0, bestWP - playedWP)
                let cls = classify(lossWinProb: loss, alternativesCount: legal.count)
                lossByColor[mover, default: []].append(loss)

                let wasBest = (played == bestMove) || loss < 0.02
                plies.append(PlyAnalysis(
                    mover: mover,
                    evalBefore: evalBeforeWhite,
                    evalAfter: evalAfterWhite,
                    bestEval: bestEvalWhite,
                    playedNotation: Notation.describe(played, before: state),
                    bestNotation: Notation.describe(bestMove, before: state),
                    bestMove: bestMove,
                    classification: cls,
                    wasBest: wasBest))

                timeline.append(evalAfterWhite)
                state = Rules.applyUnchecked(played, to: state) ?? state

                let fraction = Double(i + 1) / Double(max(moves.count, 1))
                await onProgress(fraction)
            }

            func accuracy(_ losses: [Double]) -> Double {
                guard !losses.isEmpty else { return 100 }
                let avg = losses.reduce(0, +) / Double(losses.count)
                // Map average win-prob loss to a 0–100 accuracy.
                return max(0, min(100, 100 * (1 - avg * 2.2)))
            }

            return GameAnalysis(
                plies: plies,
                whiteAccuracy: accuracy(lossByColor[.white] ?? []),
                blackAccuracy: accuracy(lossByColor[.black] ?? []),
                evalTimeline: timeline)
        }.value
    }

    /// Convert a mover-relative score to White's perspective.
    nonisolated private static func whitePerspective(_ score: Int, _ mover: PlayerColor) -> Int {
        mover == .white ? score : -score
    }

    nonisolated private static func winProbForMover(_ evalWhite: Int, mover: PlayerColor) -> Double {
        let wp = winProb(evalWhite)
        return mover == .white ? wp : 1 - wp
    }
}
