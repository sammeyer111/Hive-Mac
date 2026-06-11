import Foundation
import CryptoKit

/// Lightweight encryption for matchmaking and game traffic.
///
/// - Offers on the public broker are sealed with a key derived from the room
///   code, so a wildcard subscriber sees only ciphertext — no IPs, no tokens.
/// - Game packets are sealed with a key derived from both session tokens
///   (which only travel inside encrypted offers), so packets can't be read,
///   forged, or meaningfully replayed by a third party.
enum GameCrypto {
    static func roomKey(code: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data("hivep2p/v1|room|\(code.uppercased())".utf8)))
    }

    static func sessionKey(hostToken: String, joinerToken: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data("hivep2p/v1|session|\(hostToken)|\(joinerToken)".utf8)))
    }

    /// Shared secret both sides can derive after matchmaking; reconnection
    /// rendezvous codes and keys come from this, so only the two original
    /// players can resume a dropped game.
    static func resumeKey(hostToken: String, joinerToken: String) -> String {
        SHA256.hash(data: Data("hivep2p/v1|resume|\(hostToken)|\(joinerToken)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Deterministic 5-char room code derived from a resume key.
    static func roomCode(fromKey key: String) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let digest = SHA256.hash(data: Data("hivep2p/v1|code|\(key)".utf8))
        return String(digest.prefix(5).map { alphabet[Int($0 % 32)] })
    }

    static func seal(_ data: Data, key: SymmetricKey) -> Data? {
        try? ChaChaPoly.seal(data, using: key).combined
    }

    static func open(_ data: Data, key: SymmetricKey) -> Data? {
        guard let box = try? ChaChaPoly.SealedBox(combined: data) else { return nil }
        return try? ChaChaPoly.open(box, using: key)
    }
}
