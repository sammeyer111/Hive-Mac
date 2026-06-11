import Foundation
import SwiftUI
import HiveEngine

struct Profile: Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var emoji: String = "🐝"
    var colorHex: String = "FFB300"

    var snapshot: ProfileSnapshot {
        ProfileSnapshot(id: id, name: name, emoji: emoji, colorHex: colorHex)
    }

    static let avatarEmojis = [
        "🐝", "🐜", "🕷️", "🪲", "🦗", "🐞", "🦟", "💊",
        "🦂", "🐛", "🦋", "🐌", "🐢", "🦎", "🐸", "🦉",
        "🦊", "🐻", "🐯", "🦁", "🐵", "🤖", "👽", "🎩",
    ]

    static let accentColors = [
        "FFB300", "FF6D00", "E53935", "D81B60", "8E24AA", "5E35B1",
        "3949AB", "1E88E5", "00ACC1", "00897B", "43A047", "7CB342",
    ]
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}

/// Win/loss record against one opponent, identified by their profile ID.
struct OpponentRecord: Codable, Hashable {
    var name: String
    var emoji: String
    var colorHex: String = "888888"
    var wins = 0
    var losses = 0
    var draws = 0
}

struct Stats: Codable {
    var wins = 0
    var losses = 0
    var draws = 0
    var byOpponent: [UUID: OpponentRecord] = [:]
}

enum MatchResult {
    case win, loss, draw

    var label: String {
        switch self {
        case .win: return "Win"
        case .loss: return "Loss"
        case .draw: return "Draw"
        }
    }
}

/// A finished game, stored for the history/replay screen.
struct GameRecord: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var date: Date
    var config: GameConfig
    var startingPlayer: PlayerColor
    var myColor: PlayerColor
    var opponent: ProfileSnapshot
    var moves: [Move]
    var result: String   // "Win" / "Loss" / "Draw"
    var reason: String   // e.g. "Queen surrounded", "Kylee resigned"
    var analysis: GameAnalysis? = nil

    static func == (a: GameRecord, b: GameRecord) -> Bool {
        a.id == b.id && (a.analysis == nil) == (b.analysis == nil)
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Loads and saves the local profile and stats under Application Support.
@MainActor
final class PlayerStore: ObservableObject {
    @Published var profile: Profile?
    @Published var stats = Stats()
    @Published var games: [GameRecord] = []

    private let directory: URL
    private var profileURL: URL { directory.appendingPathComponent("profile.json") }
    private var statsURL: URL { directory.appendingPathComponent("stats.json") }
    private var gamesURL: URL { directory.appendingPathComponent("games.json") }

    init() {
        // HIVE_DATA_DIR lets a second instance use its own profile/stats
        // (useful for trying the app against yourself on one Mac).
        if let override = ProcessInfo.processInfo.environment["HIVE_DATA_DIR"] {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = appSupport.appendingPathComponent("HiveP2P", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: profileURL),
           let p = try? JSONDecoder().decode(Profile.self, from: data) {
            profile = p
        }
        if let data = try? Data(contentsOf: statsURL),
           let s = try? JSONDecoder().decode(Stats.self, from: data) {
            stats = s
        }
        if let data = try? Data(contentsOf: gamesURL),
           let g = try? JSONDecoder().decode([GameRecord].self, from: data) {
            games = g
        }
    }

    func saveGame(_ record: GameRecord) {
        games.insert(record, at: 0)
        if games.count > 200 { games.removeLast(games.count - 200) }
        if let data = try? JSONEncoder().encode(games) {
            try? data.write(to: gamesURL)
        }
    }

    func deleteGame(_ record: GameRecord) {
        games.removeAll { $0.id == record.id }
        persistGames()
    }

    func attachAnalysis(_ analysis: GameAnalysis, to recordID: UUID) {
        guard let i = games.firstIndex(where: { $0.id == recordID }) else { return }
        games[i].analysis = analysis
        persistGames()
    }

    private func persistGames() {
        if let data = try? JSONEncoder().encode(games) {
            try? data.write(to: gamesURL)
        }
    }

    func save(profile: Profile) {
        self.profile = profile
        if let data = try? JSONEncoder().encode(profile) {
            try? data.write(to: profileURL)
        }
    }

    func record(_ result: MatchResult, against opponent: ProfileSnapshot) {
        var record = stats.byOpponent[opponent.id]
            ?? OpponentRecord(name: opponent.name, emoji: opponent.emoji)
        record.name = opponent.name
        record.emoji = opponent.emoji
        record.colorHex = opponent.colorHex
        switch result {
        case .win:
            stats.wins += 1
            record.wins += 1
        case .loss:
            stats.losses += 1
            record.losses += 1
        case .draw:
            stats.draws += 1
            record.draws += 1
        }
        stats.byOpponent[opponent.id] = record
        if let data = try? JSONEncoder().encode(stats) {
            try? data.write(to: statsURL)
        }
    }

    func headToHead(_ opponentID: UUID) -> OpponentRecord? {
        stats.byOpponent[opponentID]
    }

    private func persistStats() {
        if let data = try? JSONEncoder().encode(stats) {
            try? data.write(to: statsURL)
        }
    }

    /// Wipes all stats — overall totals and every head-to-head record.
    func resetAllStats() {
        stats = Stats()
        persistStats()
    }

    /// Removes one opponent's head-to-head record and subtracts it from the
    /// overall totals, so the remaining numbers stay consistent.
    func resetRecord(against opponentID: UUID) {
        guard let record = stats.byOpponent.removeValue(forKey: opponentID) else { return }
        stats.wins = max(0, stats.wins - record.wins)
        stats.losses = max(0, stats.losses - record.losses)
        stats.draws = max(0, stats.draws - record.draws)
        persistStats()
    }
}
