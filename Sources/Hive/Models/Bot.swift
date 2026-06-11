import Foundation
import HiveEngine

/// Difficulty doubles as the think-time selector: stronger tiers search
/// longer. Beginner additionally plays deliberately loose so newcomers can win.
enum BotDifficulty: String, CaseIterable, Identifiable {
    case beginner = "Beginner"
    case snappy = "Snappy"
    case balanced = "Balanced"
    case strong = "Strong"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .beginner: return "Loose play, instant"
        case .snappy: return "~0.5s / move"
        case .balanced: return "~1.5s / move"
        case .strong: return "~3.5s / move"
        }
    }

    var limits: HiveAI.Limits {
        switch self {
        case .beginner: return .init(maxDepth: 2, maxTime: 0.15)
        case .snappy: return .init(maxDepth: 12, maxTime: 0.5)
        case .balanced: return .init(maxDepth: 16, maxTime: 1.5)
        case .strong: return .init(maxDepth: 20, maxTime: 3.5)
        }
    }

    /// Beginner sometimes plays a random legal move instead of the best one.
    var blunderChance: Double { self == .beginner ? 0.45 : 0 }

    /// Stable identity per difficulty so stats and history track each bot.
    var profile: ProfileSnapshot {
        switch self {
        case .beginner:
            return ProfileSnapshot(
                id: UUID(uuidString: "B07B07B0-0000-4000-8000-000000000001")!,
                name: "Buzz (Beginner)", emoji: "🐛", colorHex: "7CB342")
        case .snappy:
            return ProfileSnapshot(
                id: UUID(uuidString: "B07B07B0-0000-4000-8000-000000000004")!,
                name: "Dart (Snappy)", emoji: "🦗", colorHex: "00ACC1")
        case .balanced:
            return ProfileSnapshot(
                id: UUID(uuidString: "B07B07B0-0000-4000-8000-000000000002")!,
                name: "Vesper (Balanced)", emoji: "🤖", colorHex: "1E88E5")
        case .strong:
            return ProfileSnapshot(
                id: UUID(uuidString: "B07B07B0-0000-4000-8000-000000000003")!,
                name: "Apex (Strong)", emoji: "👽", colorHex: "8E24AA")
        }
    }
}

/// A PeerChannel that *is* the opponent: feeds the user's moves to the search
/// engine and delivers its replies back, so MatchSession needs no special
/// single-player code path. The user's side is always the host.
final class BotChannel: PeerChannel {
    var onMessage: ((NetMessage) -> Void)?
    var onReady: (() -> Void)?
    var onClosed: ((String?) -> Void)?

    private var game: GameState
    private var botColor: PlayerColor
    private let difficulty: BotDifficulty
    private var generation = 0
    // One engine instance: its transposition table carries across moves.
    // Tuned weights (if the background trainer has produced any) load here.
    private let engine = HiveAI(sizeMB: 48, weights: TunedWeights.load())
    private let queue = DispatchQueue(label: "hive.bot", qos: .userInitiated)

    init(start: MatchStart, difficulty: BotDifficulty) {
        self.game = GameState(config: start.config, startingPlayer: start.startingPlayer)
        self.botColor = start.yourColor
        self.difficulty = difficulty
    }

    func start() {
        DispatchQueue.main.async {
            self.onReady?()
            self.maybeMove()
        }
    }

    func send(_ message: NetMessage) {
        DispatchQueue.main.async { self.handle(message) }
    }

    func close() {}

    private func handle(_ message: NetMessage) {
        switch message {
        case .move(let move, _):
            guard let next = try? Rules.apply(move, to: game) else { return }
            game = next
            maybeMove()
        case .rematchOffer:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.onMessage?(.rematchAccept)
            }
        case .rematchStart(let start):
            generation += 1
            game = GameState(config: start.config, startingPlayer: start.startingPlayer)
            botColor = start.yourColor
            maybeMove()
        default:
            break  // resign/bye need no reply
        }
    }

    private func maybeMove() {
        guard game.outcome == nil, game.currentPlayer == botColor else { return }
        let snapshot = game
        let expectedGeneration = generation
        let difficulty = self.difficulty
        let engine = self.engine
        queue.async {
            let move: Move?
            if Double.random(in: 0...1) < difficulty.blunderChance {
                move = Rules.legalMoves(snapshot).randomElement()
            } else {
                move = engine.bestMove(snapshot, limits: difficulty.limits)
            }
            DispatchQueue.main.async {
                guard expectedGeneration == self.generation,
                      self.game.movesPlayed.count == snapshot.movesPlayed.count,
                      let move,
                      let next = try? Rules.apply(move, to: self.game) else { return }
                let turnIndex = self.game.movesPlayed.count
                self.game = next
                self.onMessage?(.move(move, turnIndex: turnIndex))
            }
        }
    }
}
