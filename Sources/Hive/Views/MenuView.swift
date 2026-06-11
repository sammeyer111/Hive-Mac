import SwiftUI

struct MenuView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("🐝 HIVE")
                .font(.system(size: 52, weight: .black, design: .rounded))
                .foregroundStyle(app.theme.accent)
            Text("Peer-to-peer • two Macs, anywhere")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            if let profile = app.store.profile {
                HStack(spacing: 14) {
                    AvatarView(emoji: profile.emoji, colorHex: profile.colorHex, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name)
                            .font(.title3.bold())
                        Text(recordLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        app.route = .editProfile
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit profile")
                }
                .padding(18)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                .padding(.top, 36)
            }

            VStack(spacing: 14) {
                Button("Create Game") { app.route = .createGame }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Join Game") { app.route = .joinGame }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Play vs Computer") { app.route = .singlePlayer }
                    .buttonStyle(SecondaryButtonStyle())
                HStack(spacing: 14) {
                    Button("Stats") { app.route = .stats }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("History") { app.route = .history }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.top, 40)

            Spacer()
            Spacer()
        }
    }

    private var recordLine: String {
        let s = app.store.stats
        return "\(s.wins)W – \(s.losses)L – \(s.draws)D"
    }
}
