import Foundation
import Network
import CryptoKit
import HiveEngine

/// Matchmaking rendezvous over a public MQTT broker, the way mobile games
/// use a matchmaking service: the host parks its punch-candidate endpoints
/// under a short room code; the joiner looks them up and posts its own; both
/// sides then hole-punch a direct UDP connection. The broker never carries
/// game traffic — only the two address exchanges, and those are encrypted
/// with a key derived from the room code, so wildcard subscribers on the
/// public broker see only ciphertext.
@MainActor
final class Rendezvous {
    static let brokers: [(String, UInt16)] = [
        ("broker.emqx.io", 1883),
        ("broker.hivemq.com", 1883),
        ("test.mosquitto.org", 1883),
    ]

    struct Offer: Codable {
        var endpoints: [UDPChannel.Endpoint]
        var name: String
        /// Session token: game packets are keyed by both sides' tokens.
        var token: String
    }

    private var client: MQTTClient?
    private var roomKey: SymmetricKey?
    private(set) var connectedBroker: String?

    var onPeerOffer: ((Offer) -> Void)?

    static func randomRoomCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<5).map { _ in alphabet.randomElement()! })
    }

    static func hostTopic(_ code: String) -> String { topic(code, role: "host") }

    private static func topic(_ code: String, role: String) -> String {
        "hivep2p/v1/\(code.uppercased())/\(role)"
    }

    /// Connects to the first broker that answers. Returns false if none did.
    /// `will`: topic to clear (empty retained message) if we vanish uncleanly.
    func connect(will willTopic: String? = nil) async -> Bool {
        for (host, port) in Self.brokers {
            if let connected = await Self.tryBroker(host: host, port: port, willTopic: willTopic) {
                client = connected
                connectedBroker = host
                connected.onClosed = { [weak self] in
                    netlog("rendezvous: broker connection lost")
                    if self?.client === connected { self?.client = nil }
                }
                netlog("rendezvous: connected to broker \(host)")
                return true
            }
            netlog("rendezvous: broker \(host) unreachable")
        }
        return false
    }

    /// Static so a late-connecting candidate can never clobber `self.client`;
    /// timeout closes the candidate outright (also resolving the continuation).
    private static func tryBroker(host: String, port: UInt16, willTopic: String?) async -> MQTTClient? {
        await withCheckedContinuation { continuation in
            let candidate = MQTTClient(host: host, port: port)
            let done = Locked(false)
            candidate.onConnected = {
                guard done.swap(true) == false else { return }
                continuation.resume(returning: candidate)
            }
            candidate.onClosed = {
                guard done.swap(true) == false else { return }
                continuation.resume(returning: nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard done.swap(true) == false else { return }
                candidate.close()
                continuation.resume(returning: nil)
            }
            candidate.connect(clientID: "hive-\(UUID().uuidString.prefix(12))", willTopic: willTopic)
        }
    }

    /// Host: park our encrypted offer (retained, so the joiner can arrive
    /// later) and listen for joiner answers.
    func publishHostOffer(code: String, offer: Offer) {
        roomKey = GameCrypto.roomKey(code: code)
        guard let client, let payload = sealedPayload(offer) else { return }
        installMessageHandler()
        client.subscribe(topic: Self.topic(code, role: "join"))
        client.publish(topic: Self.topic(code, role: "host"), payload: payload, retain: true)
    }

    /// Joiner: read the host's retained offer, then answer with our own.
    func lookupHost(code: String) {
        roomKey = GameCrypto.roomKey(code: code)
        guard let client else { return }
        installMessageHandler()
        client.subscribe(topic: Self.topic(code, role: "host"))
    }

    func publishJoinerAnswer(code: String, offer: Offer) {
        guard let client, let payload = sealedPayload(offer) else { return }
        client.publish(topic: Self.topic(code, role: "join"), payload: payload)
    }

    /// Remove the retained offer so stale codes don't linger on the broker.
    func clearHostOffer(code: String) {
        client?.publish(topic: Self.topic(code, role: "host"), payload: Data(), retain: true)
    }

    private func sealedPayload(_ offer: Offer) -> Data? {
        guard let roomKey, let json = try? JSONEncoder().encode(offer) else { return nil }
        return GameCrypto.seal(json, key: roomKey)
    }

    private func installMessageHandler() {
        client?.onMessage = { [weak self] topic, payload in
            netlog("rendezvous: message on \(topic) (\(payload.count)B)")
            guard let self, let roomKey = self.roomKey, !payload.isEmpty,
                  let json = GameCrypto.open(payload, key: roomKey),
                  let offer = try? JSONDecoder().decode(Offer.self, from: json) else { return }
            self.onPeerOffer?(offer)
        }
    }

    func close() {
        client?.close()
        client = nil
    }
}

/// Shared piece of host/join setup: open the session's UDP socket and learn
/// its public mapping via STUN, plus the LAN address for same-network punching.
enum PunchSetup {
    struct Local {
        var socket: UDPSocket
        var endpoints: [UDPChannel.Endpoint]
        var token: String
    }

    @MainActor
    static func prepare() async -> Local? {
        guard let socket = UDPSocket() else { return nil }
        guard let publicEndpoint = await STUN.publicEndpoint(using: socket) else {
            socket.shutdown()
            return nil
        }
        var endpoints = [UDPChannel.Endpoint(ip: publicEndpoint.ip, port: publicEndpoint.port)]
        if let localIP = HostSession.primaryLocalIPv4() {
            endpoints.append(UDPChannel.Endpoint(ip: localIP, port: socket.localPort))
        }
        netlog("punch setup: local port \(socket.localPort), endpoints \(endpoints.map { "\($0.ip):\($0.port)" })")
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        return Local(socket: socket, endpoints: endpoints, token: String(token))
    }
}
