import Foundation
import HiveEngine

/// Hosts a lobby: parks a room code on the public rendezvous; a joiner
/// exchanges addresses through it and the apps hole-punch a direct UDP
/// connection — the way mobile games connect. Works across the internet and
/// on the same network alike (LAN addresses are punch candidates too).
@MainActor
final class HostSession: ObservableObject {
    enum Status: Equatable {
        case settingUp     // STUN + matchmaking in progress
        case waiting       // code is live, waiting for an opponent
        case peerJoining   // punching toward a joiner
        case failed(String)
    }

    @Published var status: Status = .settingUp
    @Published var gameCode: String?

    let config: GameConfig
    private let profile: ProfileSnapshot
    private var rendezvous: Rendezvous?
    private var punchLocal: PunchSetup.Local?
    private var udpChannel: UDPChannel?
    private var matched = false
    private var cancelled = false
    private var refreshing = false
    private var resumeKey = ""
    var onMatchReady: ((PeerChannel, ProfileSnapshot, MatchStart, _ resumeKey: String) -> Void)?

    init(config: GameConfig, profile: ProfileSnapshot) {
        self.config = config
        self.profile = profile
    }

    func start() {
        Task { await startRendezvous() }
    }

    func cancel() {
        cancelled = true
        udpChannel?.close()
        udpChannel = nil
        punchLocal?.socket.shutdown()
        punchLocal = nil
        if let code = gameCode { rendezvous?.clearHostOffer(code: code) }
        rendezvous?.close()
        rendezvous = nil
    }

    private func startRendezvous() async {
        let code = Rendezvous.randomRoomCode()
        guard let local = await PunchSetup.prepare() else {
            status = .failed("Couldn't reach the address-discovery (STUN) service. Check your internet connection and try again.")
            return
        }
        guard !cancelled else {
            local.socket.shutdown()
            return
        }
        punchLocal = local
        let rendezvous = Rendezvous()
        // Last will: if we crash, the broker clears the retained offer itself.
        guard await rendezvous.connect(will: Rendezvous.hostTopic(code)) else {
            local.socket.shutdown()
            punchLocal = nil
            status = .failed("Couldn't reach the matchmaking service. Check your internet connection and try again.")
            return
        }
        guard !cancelled else {
            local.socket.shutdown()
            punchLocal = nil
            rendezvous.close()
            return
        }
        self.rendezvous = rendezvous
        rendezvous.onPeerOffer = { [weak self] offer in
            self?.handleJoinerOffer(offer)
        }
        rendezvous.publishHostOffer(
            code: code,
            offer: Rendezvous.Offer(endpoints: local.endpoints, name: profile.name, token: local.token))
        gameCode = code
        status = .waiting
        netlog("host: lobby open, code \(code)")
    }

    private func handleJoinerOffer(_ offer: Rendezvous.Offer) {
        guard !matched, !cancelled, udpChannel == nil, let local = punchLocal else { return }
        status = .peerJoining
        punchLocal = nil  // the channel owns the socket now
        resumeKey = GameCrypto.resumeKey(hostToken: local.token, joinerToken: offer.token)
        let channel = UDPChannel(
            socket: local.socket, candidates: offer.endpoints,
            sessionKey: GameCrypto.sessionKey(hostToken: local.token, joinerToken: offer.token))
        udpChannel = channel
        adopt(channel: channel)
        channel.start()
    }

    /// A failed punch consumed our socket; mint a new one and republish the
    /// offer under the same room code so the joiner can retry.
    private func refreshPunchSetup() {
        guard !refreshing, !cancelled, !matched else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            guard let local = await PunchSetup.prepare() else { return }
            guard !matched, !cancelled, let rendezvous, let code = gameCode else {
                local.socket.shutdown()
                return
            }
            punchLocal = local
            rendezvous.publishHostOffer(
                code: code,
                offer: Rendezvous.Offer(endpoints: local.endpoints, name: profile.name, token: local.token))
        }
    }

    private func adopt(channel: PeerChannel) {
        channel.onMessage = { [weak self, weak channel] message in
            guard let self, let channel else { return }
            guard case .hello(let theirProfile, let version) = message, !self.matched else { return }
            guard version == NetMessage.protocolVersion else {
                channel.send(.rejected(reason: "Version mismatch — update both apps."))
                channel.close()
                self.channelEnded()
                return
            }
            self.matched = true
            netlog("host: matched with \(theirProfile.name)")
            // Host always plays white; the joiner is black.
            let start = MatchStart(
                config: self.config,
                startingPlayer: self.config.resolveStartingPlayer(),
                yourColor: .black)
            channel.send(.welcome(profile: self.profile, start: start))
            self.shutdownRendezvous()
            // The MatchSession owns the channel now: drop our reference so a
            // later cancel() (AppState tears the lobby down when the match
            // starts) can't close the live game socket.
            self.udpChannel = nil
            self.onMatchReady?(channel, theirProfile, start, self.resumeKey)
        }
        channel.onClosed = { [weak self] _ in
            guard let self, !self.matched else { return }
            self.channelEnded()
        }
    }

    private func channelEnded() {
        udpChannel = nil
        refreshPunchSetup()
        status = .waiting
    }

    private func shutdownRendezvous() {
        punchLocal?.socket.shutdown()
        punchLocal = nil
        if let code = gameCode { rendezvous?.clearHostOffer(code: code) }
        rendezvous?.close()
        rendezvous = nil
    }

    /// Best-effort primary IPv4 (en0 etc.) for same-network punch candidates.
    nonisolated static func primaryLocalIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var best: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var addr = ifa.ifa_addr.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(&addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254") {
                    if name == "en0" { return ip }
                    best = best ?? ip
                }
            }
        }
        return best
    }
}

/// Joins a lobby by its 5-character room code.
@MainActor
final class JoinSession: ObservableObject {
    enum Status: Equatable {
        case connecting
        case failed(String)
    }

    @Published var status: Status = .connecting

    private let profile: ProfileSnapshot
    private var channel: PeerChannel?
    private var rendezvous: Rendezvous?
    private var punchLocal: PunchSetup.Local?
    private var handshakeDone = false
    private var sawHostOffer = false
    private var cancelled = false
    private var resumeKey = ""
    var onMatchReady: ((PeerChannel, ProfileSnapshot, MatchStart, _ resumeKey: String) -> Void)?

    init(profile: ProfileSnapshot) {
        self.profile = profile
    }

    func connect(code: String) {
        let compact = code.uppercased().filter { !"- ".contains($0) }
        guard compact.count == 5 else {
            status = .failed("Game codes are 5 characters, like K7Q2M.")
            return
        }
        status = .connecting
        Task {
            guard let local = await PunchSetup.prepare() else {
                status = .failed("Couldn't reach the address-discovery (STUN) service — check your internet connection.")
                return
            }
            guard !cancelled else {
                local.socket.shutdown()
                return
            }
            let rendezvous = Rendezvous()
            guard await rendezvous.connect() else {
                local.socket.shutdown()
                status = .failed("Couldn't reach the matchmaking service — check your internet connection.")
                return
            }
            guard !cancelled else {
                local.socket.shutdown()
                rendezvous.close()
                return
            }
            self.rendezvous = rendezvous
            self.punchLocal = local
            rendezvous.onPeerOffer = { [weak self] offer in
                guard let self, !self.sawHostOffer, !self.cancelled else { return }
                self.sawHostOffer = true
                netlog("join: got host offer from \(offer.name)")
                rendezvous.publishJoinerAnswer(
                    code: compact,
                    offer: Rendezvous.Offer(endpoints: local.endpoints, name: self.profile.name, token: local.token))
                self.punchLocal = nil  // the channel owns the socket now
                self.resumeKey = GameCrypto.resumeKey(hostToken: offer.token, joinerToken: local.token)
                let channel = UDPChannel(
                    socket: local.socket, candidates: offer.endpoints,
                    sessionKey: GameCrypto.sessionKey(hostToken: offer.token, joinerToken: local.token))
                self.begin(channel)
            }
            rendezvous.lookupHost(code: compact)

            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !self.sawHostOffer, !self.cancelled, self.status == .connecting {
                self.status = .failed("No open lobby found for that code. Check the code and that the host's lobby is still open.")
                self.cancel()
            }
        }
    }

    func cancel() {
        cancelled = true
        channel?.close()
        channel = nil
        punchLocal?.socket.shutdown()
        punchLocal = nil
        rendezvous?.close()
        rendezvous = nil
    }

    private func begin(_ channel: PeerChannel) {
        self.channel = channel
        status = .connecting
        channel.onReady = { [weak self, weak channel] in
            guard let self, let channel else { return }
            channel.send(.hello(profile: self.profile, protocolVersion: NetMessage.protocolVersion))
        }
        channel.onMessage = { [weak self, weak channel] message in
            guard let self, let channel else { return }
            switch message {
            case .welcome(let theirProfile, let start):
                self.handshakeDone = true
                netlog("join: matched with \(theirProfile.name)")
                self.rendezvous?.close()
                self.rendezvous = nil
                self.channel = nil  // the MatchSession owns it now
                self.onMatchReady?(channel, theirProfile, start, self.resumeKey)
            case .rejected(let reason):
                self.status = .failed(reason)
                channel.close()
            default:
                break
            }
        }
        channel.onClosed = { [weak self] reason in
            guard let self, !self.handshakeDone else { return }
            self.status = .failed(reason ?? "Could not reach the host. Check the code and that their lobby is open.")
        }
        channel.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, !self.handshakeDone, self.status == .connecting else { return }
            self.status = .failed("Connection timed out. Both lobbies may need to be reopened.")
            self.channel?.close()
        }
    }
}
