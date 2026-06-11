import SwiftUI
import HiveEngine

struct CreateGameView: View {
    @EnvironmentObject var app: AppState

    @State private var useExpansions = false
    @State private var turnChoice = TurnLength.none
    @State private var firstMove = GameConfig.FirstMove.white

    enum TurnLength: String, CaseIterable, Identifiable {
        case none = "Untimed"
        case s30 = "30 seconds"
        case m1 = "1 minute"
        case m2 = "2 minutes"
        case m5 = "5 minutes"

        var id: String { rawValue }
        var seconds: Int? {
            switch self {
            case .none: return nil
            case .s30: return 30
            case .m1: return 60
            case .m2: return 120
            case .m5: return 300
            }
        }
    }

    var body: some View {
        VStack(spacing: 26) {
            Text("Create Game")
                .font(.largeTitle.bold())
                .padding(.top, 36)

            VStack(alignment: .leading, spacing: 22) {
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
                    Text("TURN LENGTH").font(.caption.bold()).foregroundStyle(.secondary)
                    Picker("", selection: $turnChoice) {
                        ForEach(TurnLength.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("When time runs out, a random legal move is played automatically.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
                    Text("You host the lobby, so you play White in game one — colors swap each rematch.")
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
                Button("Open Lobby") {
                    let config = GameConfig(
                        useExpansions: useExpansions,
                        turnSeconds: turnChoice.seconds,
                        firstMove: firstMove)
                    app.createLobby(config: config)
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            Spacer()
        }
    }
}

struct LobbyView: View {
    @EnvironmentObject var app: AppState
    @State private var copied = false

    var body: some View {
        VStack(spacing: 22) {
            Text("Lobby Open")
                .font(.largeTitle.bold())
                .padding(.top, 40)

            if let host = app.host {
                configSummary(host.config)

                VStack(spacing: 12) {
                    switch host.status {
                    case .settingUp:
                        ProgressView()
                        Text("Setting up matchmaking\u{2026}")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    case .failed(let reason):
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .frame(maxWidth: 460)
                    default:
                        if let code = host.gameCode {
                            Text("GAME CODE").font(.caption.bold()).foregroundStyle(.secondary)
                            Text(code)
                                .font(.system(size: 56, weight: .black, design: .monospaced))
                                .foregroundStyle(Color(hex: "FFB300"))
                                .textSelection(.enabled)
                            Button(copied ? "Copied!" : "Copy Code") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                                copied = true
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            Text("Works anywhere \u{2014} same network or across the internet. The apps connect to each other directly.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 420)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .padding(26)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))

                if case .failed = host.status {} else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(host.status == .peerJoining ? "Opponent connecting\u{2026}" : "Waiting for an opponent to join\u{2026}")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button("Cancel Lobby") { app.cancelLobby() }
                .buttonStyle(SecondaryButtonStyle())

            Spacer()
        }
    }

    @ViewBuilder
    private func configSummary(_ config: GameConfig) -> some View {
        HStack(spacing: 16) {
            Label(config.useExpansions ? "Full game" : "Classic", systemImage: "hexagon")
            Label(config.turnSeconds.map { "\($0)s turns" } ?? "Untimed", systemImage: "clock")
            Label("First: \(config.firstMove.displayName)", systemImage: "flag")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
