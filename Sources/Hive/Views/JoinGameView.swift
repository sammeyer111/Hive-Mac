import SwiftUI

struct JoinGameView: View {
    @EnvironmentObject var app: AppState
    @State private var code = ""

    private var isConnecting: Bool {
        if let joiner = app.joiner, joiner.status == .connecting { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Join Game")
                .font(.largeTitle.bold())
                .padding(.top, 36)

            VStack(spacing: 14) {
                Text("ENTER GAME CODE").font(.caption.bold()).foregroundStyle(.secondary)
                TextField("K7Q2M", text: $code)
                    .textFieldStyle(.plain)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(width: 280)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .onSubmit(join)
                Button(isConnecting ? "Connecting…" : "Join") {
                    join()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(cleanedCode.count != 5 || isConnecting)
                Text("Ask the host for the code on their lobby screen.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))

            if isConnecting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to the host…")
                        .foregroundStyle(.secondary)
                }
            }

            if case .failed(let reason) = app.joiner?.status {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .frame(maxWidth: 480)
            }

            Button("Back") {
                app.cancelJoin()
                app.route = .menu
            }
            .buttonStyle(SecondaryButtonStyle())

            Spacer()
        }
    }

    private var cleanedCode: String {
        code.uppercased().filter { !"- ".contains($0) }
    }

    private func join() {
        guard !isConnecting, cleanedCode.count == 5 else { return }
        app.join(code: code)
    }
}
