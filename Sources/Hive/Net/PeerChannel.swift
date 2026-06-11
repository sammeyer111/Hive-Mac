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
/// diagnosable after the fact. HIVE_NET_DEBUG=1 echoes to stdout too.
let netDebugEnabled = ProcessInfo.processInfo.environment["HIVE_NET_DEBUG"] != nil

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
    netLogQueue.async {
        let stamp = ISO8601DateFormatter().string(from: Date())
        netLogHandle?.write(Data("\(stamp) \(text)\n".utf8))
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
