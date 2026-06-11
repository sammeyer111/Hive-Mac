import Foundation
import SwiftUI
import Combine
import HiveEngine

@MainActor
final class AppState: ObservableObject {
    enum Route: Equatable {
        case menu
        case editProfile
        case createGame
        case joinGame
        case singlePlayer
        case stats
        case history
        case replay(GameRecord)
    }

    @Published var route: Route = .menu
    @Published var host: HostSession?
    @Published var joiner: JoinSession?
    @Published var match: MatchSession?

    @Published var themeID: String {
        didSet {
            UserDefaults.standard.set(themeID, forKey: "hiveTheme")
            PrimaryButtonStyle.themeAccent = theme.accent
        }
    }
    @Published var soundsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(soundsEnabled, forKey: "hiveSounds")
            SoundPlayer.enabled = soundsEnabled
        }
    }
    @Published var pieceStyle: PieceStyle {
        didSet { UserDefaults.standard.set(pieceStyle.rawValue, forKey: "hivePieceStyle") }
    }
    @Published var material: TileMaterial {
        didSet { UserDefaults.standard.set(material.rawValue, forKey: "hiveMaterial") }
    }

    var theme: Theme { Theme.named(themeID) }

    let store = PlayerStore()
    private var storeSubscription: AnyCancellable?
    private var hostSubscription: AnyCancellable?
    private var joinerSubscription: AnyCancellable?
    private var matchSubscription: AnyCancellable?

    init() {
        themeID = UserDefaults.standard.string(forKey: "hiveTheme") ?? "honey"
        soundsEnabled = UserDefaults.standard.object(forKey: "hiveSounds") as? Bool ?? true
        pieceStyle = PieceStyle(rawValue: UserDefaults.standard.string(forKey: "hivePieceStyle") ?? "") ?? .modern
        material = TileMaterial(rawValue: UserDefaults.standard.string(forKey: "hiveMaterial") ?? "") ?? .flat
        SoundPlayer.enabled = soundsEnabled
        PrimaryButtonStyle.themeAccent = Theme.named(themeID).accent
        storeSubscription = bridge(store)
    }

    /// Views observe AppState but read state that lives on nested
    /// ObservableObjects (HostSession, JoinSession, PlayerStore). SwiftUI
    /// only watches the outermost object, so re-publish child changes —
    /// without this, screens like the lobby freeze on their first render.
    private func bridge<T: ObservableObject>(_ child: T) -> AnyCancellable
    where T.ObjectWillChangePublisher == ObservableObjectPublisher {
        child.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var needsProfile: Bool { store.profile == nil }

    // MARK: Hosting

    func createLobby(config: GameConfig) {
        guard let profile = store.profile else { return }
        let session = HostSession(config: config, profile: profile.snapshot)
        session.onMatchReady = { [weak self] peer, theirProfile, start, resumeKey in
            self?.startMatch(peer: peer, start: start, isHost: true,
                             opponent: theirProfile, resumeKey: resumeKey)
        }
        host = session
        hostSubscription = bridge(session)
        session.start()
    }

    func cancelLobby() {
        host?.cancel()
        host = nil
        route = .menu
    }

    // MARK: Joining

    func join(code: String) {
        startJoiner()?.connect(code: code)
    }

    private func startJoiner() -> JoinSession? {
        guard let profile = store.profile else { return nil }
        let session = JoinSession(profile: profile.snapshot)
        session.onMatchReady = { [weak self] peer, theirProfile, start, resumeKey in
            self?.startMatch(peer: peer, start: start, isHost: false,
                             opponent: theirProfile, resumeKey: resumeKey)
        }
        joiner = session
        joinerSubscription = bridge(session)
        return session
    }

    func cancelJoin() {
        joiner?.cancel()
        joiner = nil
    }

    // MARK: Single player

    func startSinglePlayer(config: GameConfig, difficulty: BotDifficulty) {
        guard let profile = store.profile else { return }
        let start = MatchStart(
            config: config,
            startingPlayer: config.resolveStartingPlayer(),
            yourColor: .black)  // the bot "joins"; the player hosts as white
        let bot = BotChannel(start: start, difficulty: difficulty)
        let session = MatchSession(
            peer: bot,
            start: start,
            myColor: .white,
            isHost: true,
            myProfile: profile.snapshot,
            opponentProfile: difficulty.profile,
            store: store,
            resumeKey: "")
        session.onLeave = { [weak self] in
            self?.match = nil
            self?.route = .menu
        }
        match = session
        matchSubscription = bridge(session)
        bot.start()
        route = .menu
    }

    // MARK: Reconnection

    func attemptReconnect() {
        guard let match, match.endReason == .disconnected, match.canReconnect,
              match.reconnectState != .reconnecting else { return }
        match.reconnectState = .reconnecting
        Task {
            let ok = await ResumeCoordinator.attempt(match: match)
            if !ok, match.reconnectState == .reconnecting {
                match.reconnectState = .failed
            }
        }
    }

    // MARK: Match lifecycle

    private func startMatch(peer: PeerChannel, start: MatchStart, isHost: Bool,
                            opponent: ProfileSnapshot, resumeKey: String) {
        guard let profile = store.profile else { return }
        var opponent = opponent
        opponent.name = String(opponent.name.prefix(24))
        let myColor: PlayerColor = isHost ? .white : start.yourColor
        let session = MatchSession(
            peer: peer,
            start: start,
            myColor: myColor,
            isHost: isHost,
            myProfile: profile.snapshot,
            opponentProfile: opponent,
            store: store,
            resumeKey: resumeKey)
        session.onLeave = { [weak self] in
            self?.match = nil
            self?.route = .menu
        }
        host?.cancel()
        host = nil
        joiner = nil
        match = session
        matchSubscription = bridge(session)
        route = .menu
    }
}
