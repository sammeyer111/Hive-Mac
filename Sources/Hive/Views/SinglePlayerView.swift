import SwiftUI
import HiveEngine

struct SinglePlayerView: View {
    @EnvironmentObject var app: AppState

    @State private var difficulty: BotDifficulty = .balanced
    @State private var useExpansions = false
    @State private var firstMove = GameConfig.FirstMove.white

    var body: some View {
        VStack(spacing: 26) {
            Text("Play vs Computer")
                .font(.largeTitle.bold())
                .padding(.top, 36)

            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("DIFFICULTY").font(.caption.bold()).foregroundStyle(.secondary)
                    Picker("", selection: $difficulty) {
                        ForEach(BotDifficulty.allCases) { level in
                            Text("\(level.profile.emoji) \(level.rawValue)").tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(difficulty.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("GAME").font(.caption.bold()).foregroundStyle(.secondary)
                    Picker("", selection: $useExpansions) {
                        Text("Classic").tag(false)
                        Text("Full (Ladybug • Mosquito • Pillbug)").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("FIRST TO MOVE").font(.caption.bold()).foregroundStyle(.secondary)
                    Picker("", selection: $firstMove) {
                        ForEach(GameConfig.FirstMove.allCases, id: \.self) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("You play White; the computer plays Black. Wins count in your stats.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 480)
            .padding(24)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))

            HStack(spacing: 14) {
                Button("Back") { app.route = .menu }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Start Game") {
                    let config = GameConfig(
                        useExpansions: useExpansions,
                        turnSeconds: nil,
                        firstMove: firstMove)
                    app.startSinglePlayer(config: config, difficulty: difficulty)
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            Spacer()
        }
    }
}
