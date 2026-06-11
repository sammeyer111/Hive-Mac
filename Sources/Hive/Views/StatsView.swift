import SwiftUI

struct StatsView: View {
    @EnvironmentObject var app: AppState

    @State private var confirmResetAll = false
    @State private var opponentToReset: (id: UUID, name: String)?

    private var hasStats: Bool {
        let s = app.store.stats
        return s.wins + s.losses + s.draws > 0 || !s.byOpponent.isEmpty
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Stats")
                .font(.largeTitle.bold())
                .padding(.top, 36)

            let stats = app.store.stats
            HStack(spacing: 30) {
                statBlock("\(stats.wins)", "WINS", Color(hex: "43A047"))
                statBlock("\(stats.losses)", "LOSSES", Color(hex: "E53935"))
                statBlock("\(stats.draws)", "DRAWS", Color(hex: "888888"))
            }
            .padding(24)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))

            VStack(alignment: .leading, spacing: 10) {
                Text("HEAD-TO-HEAD").font(.caption.bold()).foregroundStyle(.secondary)
                if stats.byOpponent.isEmpty {
                    Text("No games played yet. Records against each opponent appear here.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 12)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(sortedOpponents, id: \.key) { id, record in
                                HStack(spacing: 12) {
                                    AvatarView(emoji: record.emoji, colorHex: record.colorHex, size: 36)
                                    Text(record.name).font(.headline)
                                    Spacer()
                                    Text("\(record.wins) – \(record.losses)\(record.draws > 0 ? " – \(record.draws)" : "")")
                                        .font(.system(.title3, design: .monospaced).bold())
                                        .foregroundStyle(
                                            record.wins >= record.losses
                                                ? Color(hex: "43A047") : Color(hex: "E53935"))
                                    Button {
                                        opponentToReset = (id, record.name)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Clear record vs \(record.name)")
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                }
            }
            .frame(width: 460)

            HStack(spacing: 14) {
                Button("Back") { app.route = .menu }
                    .buttonStyle(SecondaryButtonStyle())
                if hasStats {
                    Button("Reset All Stats") { confirmResetAll = true }
                        .buttonStyle(SecondaryButtonStyle())
                        .tint(Color(hex: "E53935"))
                }
            }

            Spacer()
        }
        .confirmationDialog(
            "Reset all stats? This erases your overall record and every head-to-head. This can't be undone.",
            isPresented: $confirmResetAll, titleVisibility: .visible
        ) {
            Button("Reset Everything", role: .destructive) { app.store.resetAllStats() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            opponentToReset.map { "Clear your record against \($0.name)?" } ?? "",
            isPresented: Binding(
                get: { opponentToReset != nil },
                set: { if !$0 { opponentToReset = nil } }),
            titleVisibility: .visible
        ) {
            Button("Clear Record", role: .destructive) {
                if let id = opponentToReset?.id { app.store.resetRecord(against: id) }
                opponentToReset = nil
            }
            Button("Cancel", role: .cancel) { opponentToReset = nil }
        }
    }

    private var sortedOpponents: [(key: UUID, value: OpponentRecord)] {
        app.store.stats.byOpponent.sorted {
            ($0.value.wins + $0.value.losses + $0.value.draws)
                > ($1.value.wins + $1.value.losses + $1.value.draws)
        }
    }

    private func statBlock(_ number: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(number)
                .font(.system(size: 42, weight: .black, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
        .frame(width: 100)
    }
}
