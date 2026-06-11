import Foundation
import Network

/// Minimal MQTT 3.1.1 client (QoS 0 only) — just enough to use a public
/// broker as a matchmaking rendezvous. Callbacks fire on the main queue.
final class MQTTClient {
    var onConnected: (() -> Void)?
    var onMessage: ((String, Data) -> Void)?
    var onClosed: (() -> Void)?

    private let connection: NWConnection
    private var buffer = Data()
    private var packetID: UInt16 = 1
    private var pingTimer: DispatchSourceTimer?
    private var closed = false

    init(host: String, port: UInt16 = 1883) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp)
    }

    /// `willTopic`: optional MQTT Last Will — the broker publishes an empty
    /// retained message there if we vanish without a clean disconnect, so a
    /// crashed host's lobby offer can't linger.
    func connect(clientID: String, willTopic: String? = nil) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendConnect(clientID: clientID, willTopic: willTopic)
                self.startPing()
            case .failed, .cancelled:
                DispatchQueue.main.async { self.finish() }
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receiveLoop()
    }

    func close() {
        guard !closed else { return }
        closed = true
        pingTimer?.cancel()
        // Break the callback retain cycle (handlers capture their client).
        onConnected = nil
        onMessage = nil
        onClosed = nil
        connection.cancel()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        pingTimer?.cancel()
        let callback = onClosed
        onConnected = nil
        onMessage = nil
        onClosed = nil
        callback?()
    }

    // MARK: Outgoing packets

    private func sendPacket(type: UInt8, body: Data) {
        var packet = Data([type])
        // Remaining-length varint.
        var length = body.count
        repeat {
            var byte = UInt8(length % 128)
            length /= 128
            if length > 0 { byte |= 0x80 }
            packet.append(byte)
        } while length > 0
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }

    private static func encodeString(_ s: String) -> Data {
        let utf8 = Data(s.utf8)
        var data = Data([UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)])
        data.append(utf8)
        return data
    }

    private func sendConnect(clientID: String, willTopic: String?) {
        var body = MQTTClient.encodeString("MQTT")
        var flags: UInt8 = 0x02  // clean session
        if willTopic != nil {
            flags |= 0x04 | 0x20  // will flag + will retain (QoS 0)
        }
        body.append(contentsOf: [4, flags, 0, 60])  // level 4, 60s keepalive
        body.append(MQTTClient.encodeString(clientID))
        if let willTopic {
            body.append(MQTTClient.encodeString(willTopic))
            body.append(MQTTClient.encodeString(""))  // empty retained = clears the offer
        }
        sendPacket(type: 0x10, body: body)
    }

    func subscribe(topic: String) {
        packetID &+= 1
        var body = Data([UInt8(packetID >> 8), UInt8(packetID & 0xFF)])
        body.append(MQTTClient.encodeString(topic))
        body.append(0)  // QoS 0
        sendPacket(type: 0x82, body: body)
    }

    func publish(topic: String, payload: Data, retain: Bool = false) {
        var body = MQTTClient.encodeString(topic)
        body.append(payload)
        sendPacket(type: 0x30 | (retain ? 0x01 : 0x00), body: body)
    }

    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 25, repeating: 25)
        timer.setEventHandler { [weak self] in
            self?.sendPacket(type: 0xC0, body: Data())
        }
        timer.resume()
        pingTimer = timer
    }

    // MARK: Incoming packets

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data); self.drainBuffer() }
            if isComplete || error != nil {
                DispatchQueue.main.async { self.finish() }
                return
            }
            self.receiveLoop()
        }
    }

    private func drainBuffer() {
        while true {
            guard buffer.count >= 2 else { return }
            let bytes = [UInt8](buffer)
            // Decode remaining-length varint.
            var length = 0
            var multiplier = 1
            var index = 1
            while true {
                guard index < bytes.count else { return }  // need more data
                let byte = bytes[index]
                length += Int(byte & 0x7F) * multiplier
                multiplier *= 128
                index += 1
                if byte & 0x80 == 0 { break }
                guard index <= 4 else { return }
            }
            let total = index + length
            guard bytes.count >= total else { return }
            handle(type: bytes[0], body: Data(bytes[index..<total]))
            buffer.removeFirst(total)
        }
    }

    private func handle(type: UInt8, body: Data) {
        switch type & 0xF0 {
        case 0x20:  // CONNACK
            let accepted = body.count >= 2 && body[body.startIndex + 1] == 0
            DispatchQueue.main.async {
                if accepted { self.onConnected?() } else { self.finish() }
            }
        case 0x30:  // PUBLISH (QoS 0: no packet id)
            let bytes = [UInt8](body)
            guard bytes.count >= 2 else { return }
            let topicLength = Int((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            guard bytes.count >= 2 + topicLength,
                  let topic = String(bytes: bytes[2..<(2 + topicLength)], encoding: .utf8) else { return }
            let payload = Data(bytes[(2 + topicLength)...])
            DispatchQueue.main.async { self.onMessage?(topic, payload) }
        default:
            break  // SUBACK, PINGRESP, etc.
        }
    }
}
