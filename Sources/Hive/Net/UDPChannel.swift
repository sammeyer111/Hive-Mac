import Foundation
import CryptoKit
import HiveEngine

/// Reliable, ordered, encrypted NetMessage delivery over hole-punched UDP.
///
/// Punching: both peers blast small "punch" packets at each other's candidate
/// endpoints (public via STUN, private for same-LAN). Every packet is sealed
/// with the session key derived from both sides' matchmaking tokens, so a
/// third party can't read, forge, or inject traffic. The peer's address is
/// followed adaptively — we reply to wherever their newest authentic packet
/// came from (a per-packet counter stops replayed packets from steering the
/// return path).
///
/// Reliability: sliding window with cumulative acks. Every unacked message
/// is retransmitted until acknowledged, so one lost packet can never stall
/// the messages behind it. Keepalives hold the NAT mapping open; 30s of
/// silence (or 30s of an undeliverable message) fails the channel loudly.
final class UDPChannel: PeerChannel {
    var onMessage: ((NetMessage) -> Void)?
    var onReady: (() -> Void)?
    var onClosed: ((String?) -> Void)?

    struct Endpoint: Codable, Hashable {
        var ip: String
        var port: UInt16
    }

    private struct Packet: Codable {
        var c: Int           // per-transmission counter (replay/steering guard)
        var t: String        // "p" punch/ping, "d" data, "a" cumulative ack
        var s: Int?          // data: sequence; ack: highest in-order seq received
        var m: NetMessage?   // payload for "d"
    }

    /// Receive window: out-of-order packets beyond this are dropped (caps
    /// memory against buggy or hostile peers).
    private static let windowSize = 256

    private let socket: UDPSocket
    private let candidates: [Endpoint]
    private let sessionKey: SymmetricKey

    private var remote: Endpoint?
    private var closed = false
    private var lastInbound = Date()
    private var sendCounter = 0
    private var highestRecvCounter = -1

    private var nextSendSeq = 0
    private var unacked: [(seq: Int, message: NetMessage, firstSent: Date)] = []
    private var recvExpected = 0
    private var recvBuffer: [Int: NetMessage] = [:]

    private var punchTimer: DispatchSourceTimer?
    private var pumpTimer: DispatchSourceTimer?

    /// Takes ownership of the socket (closes it on teardown).
    init(socket: UDPSocket, candidates: [Endpoint], sessionKey: SymmetricKey) {
        self.socket = socket
        self.candidates = candidates
        self.sessionKey = sessionKey
    }

    func start() {
        netlog("punch: local \(socket.localPort) -> candidates \(candidates.map { "\($0.ip):\($0.port)" })")
        socket.onDatagram = { [weak self] data, ip, port in
            self?.receive(data, from: Endpoint(ip: ip, port: port))
        }

        // Punch every 300ms until first contact; give up after 20s.
        let punch = DispatchSource.makeTimerSource(queue: .main)
        var attempts = 0
        punch.schedule(deadline: .now(), repeating: 0.3)
        punch.setEventHandler { [weak self] in
            guard let self, self.remote == nil, !self.closed else {
                self?.punchTimer?.cancel()
                return
            }
            attempts += 1
            if attempts > 66 {
                self.fail("Couldn't reach the other player — both networks may be too restrictive (symmetric NAT), or the lobby is busy. Try again, or play on the same network.")
                return
            }
            if let data = self.sealed(Packet(c: self.nextCounter(), t: "p")) {
                for candidate in self.candidates {
                    self.socket.send(data, to: candidate.ip, port: candidate.port)
                }
            }
        }
        punch.resume()
        punchTimer = punch

        // Retransmit + keepalive + liveness loop.
        let pump = DispatchSource.makeTimerSource(queue: .main)
        var ticks = 0
        pump.schedule(deadline: .now() + 0.4, repeating: 0.4)
        pump.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            ticks += 1
            guard self.remote != nil else { return }
            if let oldest = self.unacked.first, Date().timeIntervalSince(oldest.firstSent) > 30 {
                self.fail("Connection to the other player was lost (a move could not be delivered).")
                return
            }
            if Date().timeIntervalSince(self.lastInbound) > 30 {
                self.fail("Connection to the other player was lost.")
                return
            }
            for entry in self.unacked.prefix(10) {
                self.transmit(Packet(c: self.nextCounter(), t: "d", s: entry.seq, m: entry.message))
            }
            if self.unacked.isEmpty && ticks % 12 == 0 {  // ~every 5s
                self.transmit(Packet(c: self.nextCounter(), t: "p"))
            }
        }
        pump.resume()
        pumpTimer = pump
    }

    func send(_ message: NetMessage) {
        DispatchQueue.main.async {
            guard !self.closed else { return }
            let seq = self.nextSendSeq
            self.nextSendSeq += 1
            self.unacked.append((seq, message, Date()))
            self.transmit(Packet(c: self.nextCounter(), t: "d", s: seq, m: message))
        }
    }

    func close() {
        DispatchQueue.main.async { self.teardown(reason: nil, notify: false) }
    }

    // MARK: Internals (all state mutations on main)

    private func nextCounter() -> Int {
        sendCounter += 1
        return sendCounter
    }

    private func sealed(_ packet: Packet) -> Data? {
        guard let json = try? JSONEncoder().encode(packet) else { return nil }
        return GameCrypto.seal(json, key: sessionKey)
    }

    private func receive(_ data: Data, from sender: Endpoint) {
        guard !closed,
              let json = GameCrypto.open(data, key: sessionKey),
              let packet = try? JSONDecoder().decode(Packet.self, from: json) else { return }
        lastInbound = Date()
        // Only fresh packets (counter the peer has never used before) may
        // move the return path; replayed packets can't steer it.
        if packet.c > highestRecvCounter {
            highestRecvCounter = packet.c
            let firstContact = remote == nil
            remote = sender
            if firstContact {
                netlog("punch: established via \(sender.ip):\(sender.port)")
                punchTimer?.cancel()
                // A reply punch lets the peer lock on immediately too.
                transmit(Packet(c: nextCounter(), t: "p"))
                onReady?()
            }
        }
        guard remote != nil else { return }

        switch packet.t {
        case "d":
            guard let seq = packet.s, let message = packet.m else { return }
            if seq >= recvExpected && seq < recvExpected + Self.windowSize
                && recvBuffer.count < Self.windowSize {
                recvBuffer[seq] = message
                while let next = recvBuffer.removeValue(forKey: recvExpected) {
                    recvExpected += 1
                    onMessage?(next)
                }
            }
            transmit(Packet(c: nextCounter(), t: "a", s: recvExpected - 1))
        case "a":
            if let acked = packet.s {
                unacked.removeAll { $0.seq <= acked }
            }
        default:
            break  // punch/ping
        }
    }

    private func transmit(_ packet: Packet) {
        guard let remote, let data = sealed(packet) else { return }
        socket.send(data, to: remote.ip, port: remote.port)
    }

    private func fail(_ reason: String) {
        netlog("channel: FAILED — \(reason) [unacked=\(unacked.count) recvExpected=\(recvExpected) inboundAge=\(Int(Date().timeIntervalSince(lastInbound)))s]")
        teardown(reason: reason, notify: true)
    }

    private func teardown(reason: String?, notify: Bool) {
        guard !closed else { return }
        closed = true
        punchTimer?.cancel()
        pumpTimer?.cancel()
        socket.shutdown()
        if notify { onClosed?(reason) }
    }
}
