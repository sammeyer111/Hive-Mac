import Foundation
import HiveEngine

@MainActor
final class TurnClock: ObservableObject {
    @Published var secondsRemaining: Int?
}

/// Drives one match (network or bot): applies local moves, validates remote
/// ones, runs the turn clock, and handles resignation, rematches (with color
/// swap), reconnection after a drop, notation, sounds, and game records.
@MainActor
final class MatchSession: ObservableObject {

    enum EndReason: Equatable {
        case outcome(Outcome)
        case opponentResigned
        case youResigned
        case disconnected
    }

    enum RematchState: Equatable {
        case none
        case offeredByMe
        case offeredByThem
        case declined
    }

    enum ReconnectState: Equatable {
        case idle
        case reconnecting
        case failed
    }

    /// Pending take-back negotiation (peer matches only).
    enum UndoState: Equatable {
        case none
        case requestedByMe
        case requestedByThem
        case declined
    }

    @Published private(set) var game: GameState
    @Published private(set) var endReason: EndReason?
    @Published var rematchState: RematchState = .none
    @Published private(set) var lastMove: Move?
    /// The most-recent move removed by the last take-back, with `undoTick`
    /// bumped each time — the board view animates this move sliding back.
    @Published private(set) var lastUndoneMove: Move?
    @Published private(set) var undoTick = 0
    @Published private(set) var opponentLeft = false
    @Published private(set) var gameGeneration = 0
    @Published private(set) var myColor: PlayerColor
    @Published private(set) var notations: [String] = []
    @Published var reconnectState: ReconnectState = .idle
    @Published var undoState: UndoState = .none

    /// True for single-player matches (the opponent is the local AI), which
    /// use instant local undo instead of the peer request/accept flow.
    let vsBot: Bool
    /// One undo request per turn: set when I send a request, cleared whenever a
    /// move is applied (i.e. the turn advances).
    private var undoRequestedThisTurn = false
    private var undoFlashTask: Task<Void, Never>?

    /// Separate observable so the per-second tick doesn't invalidate (and
    /// redraw) the board canvas — only the banners observe this.
    let clock = TurnClock()

    let isHost: Bool
    let myProfile: ProfileSnapshot
    let opponentProfile: ProfileSnapshot
    let config: GameConfig
    /// Shared secret for resuming a dropped game; empty for bot matches.
    let resumeKey: String

    private(set) var peer: PeerChannel
    private var startingPlayer: PlayerColor
    private let store: PlayerStore
    private var statsRecorded = false
    private var clockTask: Task<Void, Never>?
    private var legalMovesCache: (generation: Int, count: Int, moves: [Move])?
    var onLeave: (() -> Void)?

    var canReconnect: Bool { !resumeKey.isEmpty }

    var isMyTurn: Bool {
        game.outcome == nil && endReason == nil && game.currentPlayer == myColor
    }

    var lastMoveOrigin: Hex? {
        switch lastMove {
        case .move(_, let from, _), .pillbugMove(_, _, let from, _): return from
        default: return nil
        }
    }

    var lastMoveDestination: Hex? { lastMove?.destination }

    init(peer: PeerChannel, start: MatchStart, myColor: PlayerColor, isHost: Bool,
         myProfile: ProfileSnapshot, opponentProfile: ProfileSnapshot, store: PlayerStore,
         resumeKey: String, vsBot: Bool = false) {
        self.peer = peer
        self.config = start.config
        self.game = GameState(config: start.config, startingPlayer: start.startingPlayer)
        self.startingPlayer = start.startingPlayer
        self.myColor = myColor
        self.isHost = isHost
        self.myProfile = myProfile
        self.opponentProfile = opponentProfile
        self.store = store
        self.resumeKey = resumeKey
        self.vsBot = vsBot
        wireChannel()
        restartClock()
        SoundPlayer.play(.gameStart)
    }

    /// Cached Rules.legalMoves for the current position (move generation is
    /// expensive; views ask for this several times per render).
    func currentLegalMoves() -> [Move] {
        let key = (gameGeneration, game.movesPlayed.count)
        if let cached = legalMovesCache, cached.generation == key.0, cached.count == key.1 {
            return cached.moves
        }
        let moves = Rules.legalMoves(game)
        legalMovesCache = (key.0, key.1, moves)
        return moves
    }

    /// Identity-guarded handlers: events from a replaced (pre-reconnect)
    /// channel must not affect the session.
    private func wireChannel() {
        let current = peer
        current.onMessage = { [weak self] message in
            guard let self, self.peer === current else { return }
            self.handle(message)
        }
        current.onClosed = { [weak self] _ in
            guard let self, self.peer === current else { return }
            if self.endReason == nil {
                self.endReason = .disconnected
                self.stopClock()
            } else {
                // Peer gone after the game ended: no rematch possible.
                self.opponentLeft = true
            }
        }
    }

    // MARK: Local play

    func play(_ move: Move) {
        guard isMyTurn else { return }
        let turnIndex = game.movesPlayed.count
        let notation = Notation.describe(move, before: game)
        guard let next = try? Rules.apply(move, to: game) else { return }
        game = next
        notations.append(notation)
        lastMove = move
        netlog("match: sent move #\(turnIndex)")
        peer.send(.move(move, turnIndex: turnIndex))
        playMoveSound(move)
        afterTurnAdvanced()
    }

    // MARK: Undo / take-back

    /// Whether the undo control should be offered right now.
    var canUndo: Bool { vsBot ? canUndoSolo : canRequestUndo }

    /// Single-player: any move on the board can be taken back.
    private var canUndoSolo: Bool {
        vsBot && !game.movesPlayed.isEmpty
    }

    /// Peer match: a request may only be sent in the window after my own move
    /// (while it's the opponent's turn), once per turn, with none pending.
    private var canRequestUndo: Bool {
        !vsBot && endReason == nil && !game.movesPlayed.isEmpty
            && game.currentPlayer != myColor
            && undoState == .none && !undoRequestedThisTurn
    }

    /// Driven by the Undo button. Branches on match type.
    func undo() {
        if vsBot { undoSolo() } else { requestUndo() }
    }

    /// Instant, unlimited take-back vs the AI: rewind to the most recent
    /// position where it was my turn (undoing the bot's reply and my move),
    /// and resync the bot so it doesn't replay the discarded line.
    private func undoSolo() {
        guard canUndoSolo else { return }
        var target = game.movesPlayed.count - 1
        while target > 0 {
            let prefix = Rules.replay(
                game.movesPlayed.prefix(target), config: config, startingPlayer: startingPlayer)
            if prefix.currentPlayer == myColor { break }
            target -= 1
        }
        applyUndo(toMoveCount: target)
        peer.send(.undoSync(toMoveCount: target))
    }

    private func requestUndo() {
        guard canRequestUndo else { return }
        undoState = .requestedByMe
        undoRequestedThisTurn = true
        peer.send(.undoRequest)
    }

    /// The opponent answers my (their peer's) take-back request.
    func respondToUndo(accept: Bool) {
        guard undoState == .requestedByThem else { return }
        peer.send(.undoResponse(accepted: accept))
        if accept {
            performPeerUndo()
        } else {
            undoState = .none
        }
    }

    /// Both peers revert exactly the last move (the requester's), returning the
    /// turn to the requester.
    private func performPeerUndo() {
        guard !game.movesPlayed.isEmpty else { undoState = .none; return }
        applyUndo(toMoveCount: game.movesPlayed.count - 1)
    }

    /// Rebuilds the position at `n` moves and refreshes all derived state.
    private func applyUndo(toMoveCount n: Int) {
        let target = max(0, min(n, game.movesPlayed.count))
        // The topmost move being removed is the one the board animates backward.
        let removedTop = target < game.movesPlayed.count ? game.movesPlayed.last : nil
        game = Rules.replay(
            game.movesPlayed.prefix(target), config: config, startingPlayer: startingPlayer)
        notations = Array(notations.prefix(target))
        lastMove = game.movesPlayed.last
        endReason = nil
        undoState = .none
        undoRequestedThisTurn = false
        legalMovesCache = nil
        if let removedTop {
            lastUndoneMove = removedTop
            undoTick &+= 1
        }
        SoundPlayer.play(.undoApplied)
        restartClock()
    }

    private func flashUndoDeclined() {
        undoState = .declined
        undoFlashTask?.cancel()
        undoFlashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard let self, !Task.isCancelled, self.undoState == .declined else { return }
            self.undoState = .none
        }
    }

    func resign() {
        guard endReason == nil else { return }
        netlog("match: sent resign")
        peer.send(.resign)
        endReason = .youResigned
        stopClock()
        recordStats(.loss, reason: "You resigned")
    }

    func offerRematch() {
        guard endReason != nil, !opponentLeft else { return }
        if rematchState == .offeredByThem {
            acceptRematch()
        } else {
            rematchState = .offeredByMe
            peer.send(.rematchOffer)
        }
    }

    func declineRematch() {
        guard rematchState == .offeredByThem else { return }
        peer.send(.rematchDecline)
        rematchState = .declined
    }

    private func acceptRematch() {
        peer.send(.rematchAccept)
        if isHost {
            startHostRematch()
        }
        // Joiner waits for .rematchStart.
    }

    /// Colors swap every rematch: the joiner takes the host's current color.
    private func startHostRematch() {
        let start = MatchStart(
            config: config,
            startingPlayer: config.resolveStartingPlayer(),
            yourColor: myColor)
        peer.send(.rematchStart(start))
        beginRematch(start)
    }

    func leave() {
        peer.send(.bye)
        peer.close()
        stopClock()
        onLeave?()
    }

    // MARK: Reconnection

    /// Adopts a freshly punched channel after a drop. `syncedState` is the
    /// host's authoritative state (nil on the host side itself).
    func resume(channel: PeerChannel, syncedState: GameState?) {
        peer.close()
        peer = channel
        wireChannel()
        if let synced = syncedState {
            if game.movesPlayed.count == synced.movesPlayed.count + 1 {
                // The host missed my last move; keep my state and re-send it.
                if let missing = game.movesPlayed.last {
                    peer.send(.move(missing, turnIndex: game.movesPlayed.count - 1))
                }
            } else if synced.movesPlayed.count >= game.movesPlayed.count {
                game = synced
                rebuildDerivedState()
            }
        }
        legalMovesCache = nil
        if endReason == .disconnected { endReason = nil }
        reconnectState = .idle
        opponentLeft = false
        restartClock()
        SoundPlayer.play(.gameStart)
    }

    private func rebuildDerivedState() {
        notations = Notation.list(
            moves: game.movesPlayed, config: config, startingPlayer: startingPlayer)
        lastMove = game.movesPlayed.last
    }

    // MARK: Remote messages

    private func handle(_ message: NetMessage) {
        switch message {
        case .move(let move, let turnIndex):
            guard endReason == nil, game.currentPlayer != myColor,
                  turnIndex == game.movesPlayed.count else {
                // The local AI is trusted: a bot reply that crossed an undo
                // arrives out of step and is simply dropped, never a desync.
                if vsBot || turnIndex < game.movesPlayed.count { return }  // stale duplicate
                netlog("match: rejected remote move (turn \(turnIndex), have \(game.movesPlayed.count)) — closing")
                desync()
                return
            }
            let notation = Notation.describe(move, before: game)
            guard let next = try? Rules.apply(move, to: game) else {
                netlog("match: remote move illegal — closing")
                desync()
                return
            }
            netlog("match: received move #\(turnIndex)")
            game = next
            notations.append(notation)
            lastMove = move
            playMoveSound(move)
            afterTurnAdvanced()
        case .resign:
            guard endReason == nil else { return }
            endReason = .opponentResigned
            stopClock()
            recordStats(.win, reason: "\(opponentProfile.name) resigned")
        case .rematchOffer:
            guard endReason != nil else { return }
            if rematchState == .offeredByMe {
                // Crossing offers: both want a rematch — treat as acceptance.
                acceptRematch()
            } else {
                rematchState = .offeredByThem
            }
        case .rematchAccept:
            // Guard endReason: a stray accept must not reset a game in progress.
            if isHost, endReason != nil {
                startHostRematch()
            }
        case .rematchDecline:
            rematchState = .declined
        case .rematchStart(let start):
            if endReason != nil {
                beginRematch(start)
            }
        case .undoRequest:
            // Valid only when the peer just moved (it's now my turn) and there
            // is a move of theirs to take back.
            guard endReason == nil, !vsBot, game.currentPlayer == myColor,
                  !game.movesPlayed.isEmpty, undoState == .none else { return }
            undoState = .requestedByThem
            SoundPlayer.play(.undoAsk)
        case .undoResponse(let accepted):
            guard undoState == .requestedByMe else { return }
            if accepted {
                performPeerUndo()
            } else {
                flashUndoDeclined()
                SoundPlayer.play(.undoDecline)
            }
        case .undoSync:
            break  // host/bot-direction only; never received by the app side
        case .bye:
            if endReason == nil {
                // A deliberate mid-game quit counts as resignation.
                endReason = .opponentResigned
                stopClock()
                recordStats(.win, reason: "\(opponentProfile.name) left")
            }
            opponentLeft = true
        default:
            break
        }
    }

    private func desync() {
        endReason = .disconnected
        stopClock()
        peer.close()
    }

    private func beginRematch(_ start: MatchStart) {
        game = GameState(config: start.config, startingPlayer: start.startingPlayer)
        startingPlayer = start.startingPlayer
        myColor = isHost ? start.yourColor.opponent : start.yourColor
        endReason = nil
        rematchState = .none
        statsRecorded = false
        lastMove = nil
        notations = []
        undoState = .none
        undoRequestedThisTurn = false
        gameGeneration += 1
        legalMovesCache = nil
        netlog("match: rematch started (game \(gameGeneration + 1)), my color \(myColor.rawValue)")
        restartClock()
        SoundPlayer.play(.gameStart)
    }

    // MARK: Turn clock

    private func afterTurnAdvanced() {
        // A new move closes any open take-back window from the previous turn.
        undoRequestedThisTurn = false
        if undoState != .declined { undoState = .none }
        if let outcome = game.outcome {
            stopClock()
            endReason = .outcome(outcome)
            switch outcome {
            case .draw:
                recordStats(.draw, reason: "Both queens surrounded")
            case .win(let color):
                recordStats(color == myColor ? .win : .loss, reason: "Queen surrounded")
            }
        } else {
            restartClock()
        }
    }

    private func restartClock() {
        stopClock()
        guard let limit = config.turnSeconds, game.outcome == nil else {
            clock.secondsRemaining = nil
            return
        }
        clock.secondsRemaining = limit
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard let remaining = self.clock.secondsRemaining else { return }
                let next = remaining - 1
                self.clock.secondsRemaining = max(0, next)
                if next <= 0 {
                    // Each side enforces its own clock: a random legal move
                    // (or pass) is played automatically when time runs out.
                    if self.isMyTurn, let move = self.currentLegalMoves().randomElement() {
                        self.play(move)
                    }
                    return
                }
            }
        }
    }

    private func stopClock() {
        clockTask?.cancel()
        clockTask = nil
        clock.secondsRemaining = nil
    }

    // MARK: Sounds, stats & records

    private func playMoveSound(_ move: Move) {
        switch move {
        case .place: SoundPlayer.play(.place)
        case .move, .pillbugMove: SoundPlayer.play(.move)
        case .pass: break
        }
    }

    private func recordStats(_ result: MatchResult, reason: String) {
        guard !statsRecorded else { return }
        statsRecorded = true
        store.record(result, against: opponentProfile)
        if !game.movesPlayed.isEmpty {
            store.saveGame(GameRecord(
                date: Date(),
                config: config,
                startingPlayer: startingPlayer,
                myColor: myColor,
                opponent: opponentProfile,
                moves: game.movesPlayed,
                result: result.label,
                reason: reason))
        }
        switch result {
        case .win: SoundPlayer.play(.win)
        case .loss: SoundPlayer.play(.lose)
        case .draw: SoundPlayer.play(.draw)
        }
    }
}
