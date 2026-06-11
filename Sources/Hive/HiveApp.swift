import SwiftUI
import AppKit

struct HiveApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup("Hive") {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 860, minHeight: 640)
                .preferredColorScheme(.dark)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [app.theme.bgTop, app.theme.bgBottom],
                startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            screen
                .id(screenKey)
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
        }
        .animation(.easeInOut(duration: 0.3), value: screenKey)
    }

    /// Identity for the current screen; a change drives the crossfade above.
    private var screenKey: String {
        if app.needsProfile { return "profile" }
        if app.match != nil { return "match" }
        if app.host != nil { return "lobby" }
        return "\(app.route)"
    }

    @ViewBuilder
    private var screen: some View {
        if app.needsProfile {
            ProfileEditorView(isFirstRun: true)
        } else if let match = app.match {
            GameView(match: match)
                .id(ObjectIdentifier(match))
        } else if app.host != nil {
            LobbyView()
        } else {
            switch app.route {
            case .menu: MenuView()
            case .editProfile: ProfileEditorView(isFirstRun: false)
            case .createGame: CreateGameView()
            case .joinGame: JoinGameView()
            case .singlePlayer: SinglePlayerView()
            case .stats: StatsView()
            case .history: HistoryView()
            case .replay(let record): ReplayView(record: record)
            }
        }
    }
}

/// Circular avatar used everywhere a profile appears.
struct AvatarView: View {
    let emoji: String
    let colorHex: String
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: colorHex).gradient)
            Text(emoji)
                .font(.system(size: size * 0.55))
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    /// Updated by AppState when the theme changes; views re-render through
    /// AppState's objectWillChange and pick up the new value.
    static var themeAccent: Color = Color(hex: "FFB300")

    var color: Color?

    init(color: Color? = nil) {
        self.color = color
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.black)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(
                (color ?? Self.themeAccent).opacity(configuration.isPressed ? 0.7 : 1),
                in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .shadow(color: (color ?? Self.themeAccent).opacity(configuration.isPressed ? 0 : 0.35),
                    radius: configuration.isPressed ? 1 : 7, y: configuration.isPressed ? 0 : 3)
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { pressed in
                if pressed { SoundPlayer.play(.click) }
            }
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 11)
            .background(.white.opacity(configuration.isPressed ? 0.08 : 0.14), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { pressed in
                if pressed { SoundPlayer.play(.click) }
            }
    }
}
