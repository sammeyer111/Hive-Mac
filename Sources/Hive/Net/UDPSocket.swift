import Foundation

/// One unconnected BSD UDP socket: bound once, used for STUN discovery, hole
/// punching, and the game channel alike. A single socket per peer means the
/// NAT mapping discovered via STUN is exactly the mapping the game uses, and
/// incoming datagrams can't be misrouted between sockets sharing a port.
final class UDPSocket {
    private let fd: Int32
    let localPort: UInt16
    private var readSource: DispatchSourceRead?
    private var closed = false

    /// Datagram + sender, delivered on the main queue.
    var onDatagram: ((Data, _ ip: String, _ port: UInt16) -> Void)?

    init?() {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = 0  // kernel picks
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(sock)
            return nil
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &length)
            }
        }
        guard got == 0 else {
            close(sock)
            return nil
        }
        fd = sock
        localPort = UInt16(bigEndian: actual.sin_port)
        startReceiving()
    }

    private func startReceiving() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 2048)
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { senderPtr in
                    recvfrom(self.fd, &buffer, buffer.count, 0, senderPtr, &senderLength)
                }
            }
            guard count > 0 else { return }
            let data = Data(buffer[0..<count])
            var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sender.sin_addr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: ipBuffer)
            let port = UInt16(bigEndian: sender.sin_port)
            DispatchQueue.main.async {
                self.onDatagram?(data, ip, port)
            }
        }
        source.resume()
        readSource = source
    }

    func send(_ data: Data, to ip: String, port: UInt16) {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_aton(ip, &addr.sin_addr) != 0 else { return }
        _ = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                    sendto(fd, bytes.baseAddress, data.count, 0, addrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func shutdown() {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        close(fd)
    }

    deinit {
        shutdown()
    }

    /// Blocking IPv4 DNS lookup (call off the main thread).
    static func resolveIPv4(_ host: String) -> String? {
        // Already dotted-quad?
        var probe = in_addr()
        if inet_aton(host, &probe) != 0 { return host }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &results) == 0, let first = results else { return nil }
        defer { freeaddrinfo(results) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            if current.pointee.ai_family == AF_INET, let sa = current.pointee.ai_addr {
                var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
                return String(cString: ipBuffer)
            }
            node = current.pointee.ai_next
        }
        return nil
    }
}
