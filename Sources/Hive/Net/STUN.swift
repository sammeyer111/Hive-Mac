import Foundation

/// Minimal STUN client (RFC 5389): asks a public STUN server "what address
/// do you see me as?" over the same socket the game will use, so the
/// discovered NAT mapping is exactly the one the peer punches toward.
enum STUN {
    static let servers: [(String, UInt16)] = [
        ("stun.l.google.com", 19302),
        ("stun.cloudflare.com", 3478),
        ("stun1.l.google.com", 19302),
    ]

    @MainActor
    static func publicEndpoint(using socket: UDPSocket) async -> (ip: String, port: UInt16)? {
        for (host, port) in servers {
            let server = await Task.detached { UDPSocket.resolveIPv4(host) }.value
            guard let server else { continue }
            if let result = await query(socket: socket, serverIP: server, serverPort: port) {
                return result
            }
        }
        return nil
    }

    @MainActor
    private static func query(socket: UDPSocket, serverIP: String, serverPort: UInt16) async -> (ip: String, port: UInt16)? {
        // Binding request: type 0x0001, length 0, magic cookie, random txn id.
        let txid = (0..<12).map { _ in UInt8.random(in: 0...255) }
        let request = Data([0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42] + txid)

        return await withCheckedContinuation { continuation in
            let done = Locked(false)
            func finish(_ result: (String, UInt16)?) {
                guard done.swap(true) == false else { return }
                socket.onDatagram = nil
                continuation.resume(returning: result)
            }
            socket.onDatagram = { data, ip, port in
                guard ip == serverIP, port == serverPort else { return }
                if let parsed = parse(response: data, txid: txid) {
                    finish(parsed)
                }
            }
            socket.send(request, to: serverIP, port: serverPort)
            // One retransmit at 1s (harmless if already answered), give up at 2.5s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                socket.send(request, to: serverIP, port: serverPort)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { finish(nil) }
        }
    }

    private static func parse(response: Data, txid: [UInt8]) -> (String, UInt16)? {
        let bytes = [UInt8](response)
        // Success response 0x0101, cookie + matching transaction id.
        guard bytes.count >= 20, bytes[0] == 0x01, bytes[1] == 0x01,
              Array(bytes[8..<20]) == txid else { return nil }
        var i = 20
        var fallback: (String, UInt16)?
        while i + 4 <= bytes.count {
            let type = (UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1])
            let length = Int((UInt16(bytes[i + 2]) << 8) | UInt16(bytes[i + 3]))
            let valueStart = i + 4
            guard valueStart + length <= bytes.count else { return fallback }
            if (type == 0x0020 || type == 0x0001), length >= 8, bytes[valueStart + 1] == 0x01 {
                var port = (UInt16(bytes[valueStart + 2]) << 8) | UInt16(bytes[valueStart + 3])
                var addr = Array(bytes[(valueStart + 4)..<(valueStart + 8)])
                if type == 0x0020 {  // XOR-MAPPED-ADDRESS
                    port ^= 0x2112
                    let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
                    for j in 0..<4 { addr[j] ^= cookie[j] }
                    return ("\(addr[0]).\(addr[1]).\(addr[2]).\(addr[3])", port)
                }
                fallback = ("\(addr[0]).\(addr[1]).\(addr[2]).\(addr[3])", port)
            }
            i = valueStart + length + (4 - length % 4) % 4  // attributes pad to 4
        }
        return fallback
    }
}
