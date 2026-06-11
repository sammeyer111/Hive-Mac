import Foundation

/// Profile data exchanged between peers.
public struct ProfileSnapshot: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var emoji: String
    public var colorHex: String

    public init(id: UUID, name: String, emoji: String, colorHex: String) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.colorHex = colorHex
    }
}

/// Parameters needed to begin (or restart) a match. Created by the host.
public struct MatchStart: Codable, Hashable, Sendable {
    public var config: GameConfig
    public var startingPlayer: PlayerColor
    /// Color assigned to the receiving (joining) peer. The host is always white.
    public var yourColor: PlayerColor

    public init(config: GameConfig, startingPlayer: PlayerColor, yourColor: PlayerColor) {
        self.config = config
        self.startingPlayer = startingPlayer
        self.yourColor = yourColor
    }
}

/// Messages exchanged over the wire, length-prefixed JSON.
public enum NetMessage: Codable, Sendable {
    /// Joiner → host, immediately after connecting.
    case hello(profile: ProfileSnapshot, protocolVersion: Int)
    /// Host → joiner: accepted; game begins.
    case welcome(profile: ProfileSnapshot, start: MatchStart)
    /// Host → joiner when the lobby is busy or versions mismatch.
    case rejected(reason: String)
    /// A turn was taken. `turnIndex` is the count of moves played before this one.
    case move(Move, turnIndex: Int)
    case resign
    case rematchOffer
    case rematchAccept
    case rematchDecline
    /// Host → joiner after both sides agree to a rematch.
    case rematchStart(MatchStart)
    /// Host → joiner over a reconnected channel: authoritative game state.
    case resumeState(GameState)
    case bye

    public static let protocolVersion = 4
}

public enum NetCodec {
    public static func encode(_ message: NetMessage) throws -> Data {
        let body = try JSONEncoder().encode(message)
        var length = UInt32(body.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        return data
    }

    public static func decodeBody(_ data: Data) throws -> NetMessage {
        try JSONDecoder().decode(NetMessage.self, from: data)
    }
}
