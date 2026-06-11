import SwiftUI
import HiveEngine

struct GameView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var match: MatchSession

    @State private var selection: Selection = .none
    @State private var showResignConfirm = false
    @AppStorage("hiveShowMoves") private var showMoves = false

    enum Selection: Equatable {
        case none
        case hand(PieceKind)
        case board(pieceID: String, at: Hex)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        PlayerBanner(
                            profile: match.opponentProfile,
                            color: match.myColor.opponent,
                            isActive: match.game.currentPlayer == match.myColor.opponent
                                && match.game.outcome == nil && match.endReason == nil,
                            clock: match.clock,
                            showClock: match.game.currentPlayer == match.myColor.opponent,
                            headToHead: headToHeadText)
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showMoves.toggle() }
                        } label: {
                            Image(systemName: "list.bullet.rectangle")
                                .font(.title3)
                                .foregroundStyle(showMoves ? app.theme.accent : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Move list")
                    }
                    OpponentHandTray(match: match)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)

                BoardCanvas(match: match, selection: $selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) { turnRibbon }
                    .overlay(alignment: .bottom) { undoBanner }
                    .overlay { gameOverOverlay }

                myControls
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }

            if showMoves {
                MoveListView(notations: match.notations)
                    .frame(width: 180)
                    .padding(.vertical, 10)
                    .padding(.trailing, 10)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onChange(of: match.game.movesPlayed.count) { _ in
            selection = .none
        }
        .onChange(of: match.gameGeneration) { _ in
            selection = .none
        }
        .onChange(of: match.endReason) { reason in
            // Lost the link mid-game: try to re-establish it automatically.
            if reason == .disconnected && match.canReconnect {
                app.attemptReconnect()
            }
        }
    }

    private var headToHeadText: String? {
        guard let record = app.store.headToHead(match.opponentProfile.id) else { return nil }
        return "vs you: \(record.losses) – \(record.wins)"
    }

    // MARK: Bottom bar

    private var myControls: some View {
        VStack(spacing: 10) {
            HandTray(match: match, selection: $selection)
            HStack {
                PlayerBanner(
                    profile: match.myProfile,
                    color: match.myColor,
                    isActive: match.isMyTurn,
                    clock: match.clock,
                    showClock: match.isMyTurn && match.endReason == nil,
                    headToHead: nil)
                Spacer()
                if mustPass {
                    Button("Pass Turn") { match.play(.pass) }
                        .buttonStyle(PrimaryButtonStyle())
                }
                if match.canUndo {
                    Button {
                        match.undo()
                    } label: {
                        Label(match.vsBot ? "Undo" : "Ask Undo", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help(match.vsBot
                          ? "Take back your last move"
                          : "Ask \(match.opponentProfile.name) to take back your last move")
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                if match.endReason == nil {
                    Button("Resign") { showResignConfirm = true }
                        .buttonStyle(SecondaryButtonStyle())
                        .confirmationDialog("Resign this game?", isPresented: $showResignConfirm) {
                            Button("Resign", role: .destructive) { match.resign() }
                        }
                } else {
                    Button("Leave") { match.leave() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: match.canUndo)
        }
    }

    private var mustPass: Bool {
        match.isMyTurn && match.currentLegalMoves() == [.pass]
    }

    private var turnRibbon: some View {
        Group {
            if match.endReason == nil {
                Text(match.isMyTurn ? "Your turn" : "\(match.opponentProfile.name)'s turn")
                    .font(.callout.bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(
                        match.isMyTurn ? app.theme.accent : .white.opacity(0.12),
                        in: Capsule())
                    .foregroundStyle(match.isMyTurn ? .black : .white)
                    .padding(.top, 8)
                    .animation(.easeInOut(duration: 0.2), value: match.isMyTurn)
            }
        }
    }

    // MARK: Undo / take-back banner

    @ViewBuilder
    private var undoBanner: some View {
        Group {
            switch match.undoState {
            case .requestedByMe:
                undoChip {
                    Label("Take-back requested…", systemImage: "hourglass")
                        .font(.callout.bold())
                }
            case .requestedByThem:
                VStack(spacing: 10) {
                    Text("\(match.opponentProfile.name) wants to take back their last move.")
                        .font(.callout.bold())
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button("Allow") { match.respondToUndo(accept: true) }
                            .buttonStyle(PrimaryButtonStyle(color: Color(hex: "43A047")))
                        Button("Decline") { match.respondToUndo(accept: false) }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(18)
                .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.15)))
            case .declined:
                undoChip {
                    Label("Take-back declined", systemImage: "xmark.circle")
                        .font(.callout.bold())
                }
            case .none:
                EmptyView()
            }
        }
        .padding(.bottom, 14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: match.undoState)
    }

    private func undoChip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.black.opacity(0.78), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.14)))
    }

    // MARK: Game over / reconnect overlay

    @ViewBuilder
    private var gameOverOverlay: some View {
        if let reason = match.endReason {
            VStack(spacing: 18) {
                Text(resultEmoji(reason))
                    .font(.system(size: 64))
                Text(resultTitle(reason))
                    .font(.largeTitle.bold())
                Text(resultSubtitle(reason))
                    .foregroundStyle(.secondary)

                if reason == .disconnected && match.canReconnect {
                    reconnectSection
                } else if match.opponentLeft {
                    Label("\(match.opponentProfile.name) left the game.", systemImage: "door.left.hand.open")
                        .foregroundStyle(.secondary)
                } else if reason != .disconnected {
                    rematchSection
                }

                Button("Back to Menu") { match.leave() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(40)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.15)))
            .transition(.scale(scale: 0.88).combined(with: .opacity))
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: match.endReason)
        }
    }

    @ViewBuilder
    private var reconnectSection: some View {
        switch match.reconnectState {
        case .reconnecting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reconnecting…").foregroundStyle(.secondary)
            }
        case .failed:
            VStack(spacing: 10) {
                Text("Couldn't reconnect — \(match.opponentProfile.name) may still be trying.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Try Again") { app.attemptReconnect() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        case .idle:
            Button("Reconnect") { app.attemptReconnect() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    @ViewBuilder
    private var rematchSection: some View {
        switch match.rematchState {
        case .none:
            VStack(spacing: 6) {
                Button("Offer Rematch") { match.offerRematch() }
                    .buttonStyle(PrimaryButtonStyle())
                Text("Colors swap: you'd play \(match.myColor.opponent.displayName).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .offeredByMe:
            Label("Rematch offered — waiting…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .offeredByThem:
            HStack(spacing: 12) {
                Button("Accept Rematch") { match.offerRematch() }
                    .buttonStyle(PrimaryButtonStyle(color: Color(hex: "43A047")))
                Button("Decline") { match.declineRematch() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        case .declined:
            Label("Rematch declined.", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func didIWin(_ reason: MatchSession.EndReason) -> Bool? {
        switch reason {
        case .outcome(.win(let color)): return color == match.myColor
        case .outcome(.draw): return nil
        case .opponentResigned: return true
        case .youResigned: return false
        case .disconnected: return nil
        }
    }

    private func resultEmoji(_ reason: MatchSession.EndReason) -> String {
        if reason == .disconnected { return "🔌" }
        switch didIWin(reason) {
        case true: return "🏆"
        case false: return "💀"
        default: return "🤝"
        }
    }

    private func resultTitle(_ reason: MatchSession.EndReason) -> String {
        if reason == .disconnected { return "Connection lost" }
        switch didIWin(reason) {
        case true: return "You win!"
        case false: return "You lose"
        default: return "Draw"
        }
    }

    private func resultSubtitle(_ reason: MatchSession.EndReason) -> String {
        switch reason {
        case .outcome(.win(let color)):
            return "\(color.opponent.displayName)'s queen was surrounded."
        case .outcome(.draw):
            return "Both queens were surrounded at once."
        case .opponentResigned:
            return "\(match.opponentProfile.name) resigned."
        case .youResigned:
            return "You resigned."
        case .disconnected:
            return "The connection to \(match.opponentProfile.name) was lost."
        }
    }
}

// MARK: - Player banner

struct PlayerBanner: View {
    let profile: ProfileSnapshot
    let color: PlayerColor
    let isActive: Bool
    @ObservedObject var clock: TurnClock
    let showClock: Bool
    let headToHead: String?

    private var secondsRemaining: Int? {
        showClock ? clock.secondsRemaining : nil
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(emoji: profile.emoji, colorHex: profile.colorHex, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(color == .white ? Color(hex: "F2E8C9") : Color(hex: "3A3A45"))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 0.5))
                    Text(color.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let headToHead {
                        Text(headToHead)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if let seconds = secondsRemaining {
                Text(clockText(seconds))
                    .font(.system(.title3, design: .monospaced).bold())
                    .foregroundStyle(seconds <= 10 ? .red : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer()
        }
        .padding(10)
        .background(
            isActive ? Color(hex: profile.colorHex).opacity(0.18) : .white.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isActive ? Color(hex: profile.colorHex) : .clear, lineWidth: 1.5))
        .animation(.easeInOut(duration: 0.25), value: isActive)
    }

    private func clockText(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Hand tray

struct HandTray: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var match: MatchSession
    @Binding var selection: GameView.Selection

    var body: some View {
        HStack(spacing: 8) {
            ForEach(kinds, id: \.self) { kind in
                let count = match.game.handCount(match.myColor, kind)
                let placeable = placeableKinds.contains(kind)
                Button {
                    if case .hand(let k) = selection, k == kind {
                        selection = .none
                    } else {
                        selection = .hand(kind)
                    }
                } label: {
                    VStack(spacing: 2) {
                        trayGlyph(kind)
                        Text("×\(count)")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 52, height: 56)
                    .background(
                        isSelected(kind) ? app.theme.accent.opacity(0.4) : .white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected(kind) ? app.theme.accent : .clear, lineWidth: 2))
                    .opacity(count > 0 && placeable ? 1 : 0.35)
                }
                .buttonStyle(.plain)
                .disabled(count == 0 || !placeable)
                .help(kind.displayName)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func trayGlyph(_ kind: PieceKind) -> some View {
        if let image = PieceArt.shared.image(kind: kind, color: match.myColor, style: app.pieceStyle) {
            image
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .padding(2)
                .background(
                    // Carbon silhouettes need a contrasting backing chip.
                    app.pieceStyle == .carbon
                        ? (match.myColor == .white ? app.theme.tileLight : app.theme.tileDark)
                        : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        } else {
            Text(kind.emoji).font(.system(size: 26))
        }
    }

    private var kinds: [PieceKind] {
        PieceKind.trayOrder.filter { match.config.pieceCounts.keys.contains($0) }
    }

    private func isSelected(_ kind: PieceKind) -> Bool {
        if case .hand(let k) = selection { return k == kind }
        return false
    }

    private var placeableKinds: Set<PieceKind> {
        guard match.isMyTurn else { return [] }
        var result: Set<PieceKind> = []
        for move in match.currentLegalMoves() {
            if case .place(let piece, _) = move { result.insert(piece.kind) }
        }
        return result
    }
}

// MARK: - Opponent's unplayed pieces

/// A compact, read-only readout of the pieces the opponent still has in hand.
struct OpponentHandTray: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var match: MatchSession

    private var opponentColor: PlayerColor { match.myColor.opponent }

    var body: some View {
        HStack(spacing: 6) {
            Text("In hand")
                .font(.caption2.bold())
                .foregroundStyle(.tertiary)
            ForEach(kinds, id: \.self) { kind in
                let count = match.game.handCount(opponentColor, kind)
                HStack(spacing: 3) {
                    glyph(kind)
                    Text("\(count)")
                        .font(.caption2.monospacedDigit().bold())
                        .foregroundStyle(count > 0 ? .secondary : .tertiary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .opacity(count > 0 ? 1 : 0.4)
                .help("\(kind.displayName): \(count) left")
                .animation(.easeInOut(duration: 0.2), value: count)
            }
            Spacer()
        }
    }

    private var kinds: [PieceKind] {
        PieceKind.trayOrder.filter { match.config.pieceCounts.keys.contains($0) }
    }

    @ViewBuilder
    private func glyph(_ kind: PieceKind) -> some View {
        if let image = PieceArt.shared.image(kind: kind, color: opponentColor, style: app.pieceStyle) {
            image
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .padding(1)
                .background(
                    app.pieceStyle == .carbon
                        ? (opponentColor == .white ? app.theme.tileLight : app.theme.tileDark)
                        : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        } else {
            Text(kind.emoji).font(.system(size: 16))
        }
    }
}
