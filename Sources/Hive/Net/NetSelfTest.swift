import Foundation
import HiveEngine

/// Headless network checks, run via command-line flags (never in the GUI):
/// - `--selftest-udp`: loopback hole punch + ordered delivery, no internet.
/// - `--selftest-rendezvous`: full internet path — STUN, public matchmaking
///   broker, UDP hole punch, handshake, move — host and joiner in-process.
@MainActor
enum NetSelfTest {

    private static func pump(until done: () -> Bool, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    /// Two UDPChannels punch each other over 127.0.0.1 and exchange a burst
    /// of messages each way; checks ordered, complete delivery.
    static func runUDPLoopbackAndExit() {
        guard let socketA = UDPSocket(), let socketB = UDPSocket() else {
            print("selftest: FAIL — could not open sockets")
            exit(1)
        }
        let key = GameCrypto.sessionKey(hostToken: "token-a", joinerToken: "token-b")
        let a = UDPChannel(
            socket: socketA,
            candidates: [.init(ip: "127.0.0.1", port: socketB.localPort)],
            sessionKey: key)
        let b = UDPChannel(
            socket: socketB,
            candidates: [.init(ip: "127.0.0.1", port: socketA.localPort)],
            sessionKey: key)

        let messages = (0..<8).map { NetMessage.move(.pass, turnIndex: $0) }
        var gotA: [Int] = []
        var gotB: [Int] = []
        a.onMessage = { if case .move(_, let i) = $0 { gotA.append(i) } }
        b.onMessage = { if case .move(_, let i) = $0 { gotB.append(i) } }
        a.onReady = { for m in messages { a.send(m) } }
        b.onReady = { for m in messages { b.send(m) } }
        a.start()
        b.start()

        pump(until: { gotA.count == 8 && gotB.count == 8 }, seconds: 10)
        a.close()
        b.close()
        let ok = gotA == Array(0..<8) && gotB == Array(0..<8)
        print(ok ? "selftest: PASS — UDP loopback punch + ordered delivery OK"
                 : "selftest: FAIL — A got \(gotA), B got \(gotB)")
        exit(ok ? 0 : 1)
    }

    /// Common host/join harness: wires both sessions, waits for the joiner's
    /// reply move to reach the host. `connect` kicks off the join once the
    /// host is ready and returns true when it has done so.
    private static func runMatch(host: HostSession, joiner: JoinSession,
                                 connect: () -> Bool, timeout: TimeInterval) -> Bool {
        var hostGame: GameState?
        var moveEchoed = false
        var failure: String?
        // Retain the match channels like MatchSession does in the app —
        // the sessions hand off ownership at match start.
        var liveChannels: [PeerChannel] = []

        host.onMatchReady = { channel, theirProfile, start, _ in
            // Mirror AppState.startMatch: the lobby is cancelled as soon as
            // the match begins. The game channel must survive this.
            liveChannels.append(channel)
            host.cancel()
            hostGame = GameState(config: start.config, startingPlayer: start.startingPlayer)
            guard theirProfile.name == "JoinBot" else {
                failure = "host saw wrong profile"
                return
            }
            channel.onMessage = { message in
                if case .move(let move, _) = message {
                    if let game = hostGame, let next = try? Rules.apply(move, to: game) {
                        hostGame = next
                        moveEchoed = true
                    } else {
                        failure = "host rejected joiner's move"
                    }
                }
            }
            if let game = hostGame, let move = Rules.legalMoves(game).first {
                hostGame = try? Rules.apply(move, to: game)
                channel.send(.move(move, turnIndex: 0))
            }
        }

        joiner.onMatchReady = { channel, theirProfile, start, _ in
            liveChannels.append(channel)
            joiner.cancel()  // mirror AppState clearing the join session
            var joinGame = GameState(config: start.config, startingPlayer: start.startingPlayer)
            guard theirProfile.name == "HostBot", start.yourColor == .black else {
                failure = "joiner saw wrong profile or color"
                return
            }
            channel.onMessage = { message in
                if case .move(let move, _) = message {
                    guard let next = try? Rules.apply(move, to: joinGame) else {
                        failure = "joiner rejected host's move"
                        return
                    }
                    joinGame = next
                    if let reply = Rules.legalMoves(next).first {
                        joinGame = (try? Rules.apply(reply, to: next)) ?? joinGame
                        channel.send(.move(reply, turnIndex: 1))
                    }
                }
            }
        }

        host.start()
        var connected = false
        pump(until: {
            if !connected { connected = connect() }
            return moveEchoed || failure != nil
        }, seconds: timeout)

        if let failure { print("selftest: FAIL — \(failure)") }
        else if !moveEchoed { print("selftest: FAIL — timed out") }
        for channel in liveChannels { channel.close() }
        return moveEchoed && failure == nil
    }

    /// Full internet path with real STUN + matchmaking broker + hole punch.
    static func runRendezvousAndExit() {
        let hostProfile = ProfileSnapshot(id: UUID(), name: "HostBot", emoji: "🐝", colorHex: "FFB300")
        let joinProfile = ProfileSnapshot(id: UUID(), name: "JoinBot", emoji: "🐜", colorHex: "1E88E5")
        let config = GameConfig(useExpansions: true, turnSeconds: nil, firstMove: .white)
        let host = HostSession(config: config, profile: hostProfile)
        let joiner = JoinSession(profile: joinProfile)

        let ok = runMatch(host: host, joiner: joiner, connect: {
            if case .failed(let reason) = host.status {
                print("selftest: host failed — \(reason)")
                return false
            }
            guard let code = host.gameCode else { return false }
            print("selftest: room code \(code)")
            joiner.connect(code: code)
            return true
        }, timeout: 40)
        host.cancel()
        joiner.cancel()
        print(ok ? "selftest: PASS — rendezvous + hole punch + move round-trip OK"
                 : "selftest: rendezvous path failed")
        exit(ok ? 0 : 1)
    }
}
