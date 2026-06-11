import Foundation
import HiveEngine

/// A reliable, ordered NetMessage channel between the two players.
/// UDPChannel (hole-punched, internet or LAN) is the sole transport.
/// Callbacks fire on the main queue.
protocol PeerChannel: AnyObject {
    var onMessage: ((NetMessage) -> Void)? { get set }
    var onReady: (() -> Void)? { get set }
    var onClosed: ((String?) -> Void)? { get set }
    func start()
    func send(_ message: NetMessage)
    func close()
}

/// Connection events always append to ~/Library/Logs/Hive-net.log (tiny,
/// event-level only — no per-packet spam) so problems in the field are
/// diagnosable after the fact. IP addresses are redacted to short
/// non-reversible tags in the on-disk log; HIVE_NET_DEBUG=1 echoes the full
/// (unredacted) detail to stdout for live debugging.
let netDebugEnabled = ProcessInfo.processInfo.environment["HIVE_NET_DEBUG"] != nil

/// Per-process salt so redacted tags can't be correlated across runs or
/// reversed into the original address.
private let netLogSalt = UInt64.random(in: .min ... .max)
private let ipv4Regex = try! NSRegularExpression(pattern: #"\b\d{1,3}(?:\.\d{1,3}){3}\b"#)
private let ipv6Regex = try! NSRegularExpression(pattern: #"\b(?:[0-9a-fA-F]{1,4}:){2,}[0-9a-fA-F]{0,4}\b"#)

/// Replaces an address with a stable-within-process tag like `ip3f2a`, so logs
/// stay correlatable ("punched via the same candidate") without exposing IPs.
private func redactAddress(_ raw: String) -> String {
    var hash = netLogSalt
    for byte in raw.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
    return String(format: "ip%04x", UInt16(truncatingIfNeeded: hash))
}

/// Masks every IPv4/IPv6 address in a log line, leaving ports and other text
/// (which reveal nothing sensitive) intact.
func redactNetAddresses(_ line: String) -> String {
    let result = NSMutableString(string: line)
    for regex in [ipv4Regex, ipv6Regex] {
        let matches = regex.matches(in: result as String,
                                    range: NSRange(location: 0, length: result.length))
        for match in matches.reversed() {
            let token = redactAddress(result.substring(with: match.range))
            result.replaceCharacters(in: match.range, with: token)
        }
    }
    return result as String
}

private let netLogQueue = DispatchQueue(label: "hive.netlog")
private let netLogHandle: FileHandle? = {
    let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let url = logs.appendingPathComponent("Hive-net.log")
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try? FileHandle(forWritingTo: url)
    _ = try? handle?.seekToEnd()
    return handle
}()

func netlog(_ message: @autoclosure () -> String) {
    let text = message()
    if netDebugEnabled { print("net: \(text)") }
    let safe = redactNetAddresses(text)
    netLogQueue.async {
        let stamp = ISO8601DateFormatter().string(from: Date())
        netLogHandle?.write(Data("\(stamp) \(safe)\n".utf8))
    }
}

/// Tiny lock wrapper guarding one-shot continuations in callback-based code.
final class Locked<T> {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func swap(_ newValue: T) -> T {
        lock.lock()
        defer { lock.unlock() }
        let old = value
        value = newValue
        return old
    }
}

/// Runs an async operation with a hard deadline; nil on timeout.
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
