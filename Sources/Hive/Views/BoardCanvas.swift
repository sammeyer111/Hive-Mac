import SwiftUI
import HiveEngine

/// Renders the hive and handles selection, tap-to-move, drag-to-move,
/// pan/zoom, and the subtle move animation.
struct BoardCanvas: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var match: MatchSession
    @Binding var selection: GameView.Selection

    // Pan & zoom (user transform applied on top of auto-fit).
    @State private var baseScale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
    @State private var baseOffset: CGSize = .zero
    @State private var panTranslation: CGSize = .zero

    // Drag-to-move.
    private struct DragState {
        var pieceID: String
        var from: Hex
        var point: CGPoint
    }
    @State private var drag: DragState?
    @State private var panning = false

    // Move animation.
    @State private var animationStart: Date?

    private static let animationDuration: TimeInterval = 0.28

    private var isTransformed: Bool {
        abs(baseScale - 1) > 0.01 || baseOffset != .zero || gestureScale != 1 || panTranslation != .zero
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = layout(in: proxy.size)
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: animationStart == nil)) { timeline in
                Canvas { context, _ in
                    draw(in: &context, geometry: geometry, now: timeline.date)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in
                handleTap(at: geometry.hex(at: point))
            }
            .gesture(dragGesture(geometry: geometry))
            .gesture(magnification)
        }
        .overlay(alignment: .bottomTrailing) { viewControls }
        .onChange(of: match.game.movesPlayed.count) { count in
            guard count > 0 else { return }
            animationStart = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.animationDuration + 0.1) {
                if let start = animationStart,
                   Date().timeIntervalSince(start) > Self.animationDuration {
                    animationStart = nil  // pause the timeline again
                }
            }
        }
        .onChange(of: match.gameGeneration) { _ in
            animationStart = nil
            resetView()
        }
        .padding(8)
    }

    // MARK: Layout

    private func relevantHexes() -> Set<Hex> {
        var hexes = Set(match.game.board.occupiedHexes)
        hexes.formUnion(targetHexes())
        return hexes
    }

    private func layout(in size: CGSize) -> BoardGeometry {
        var geometry = BoardGeometry.fit(hexes: relevantHexes(), in: size)
        let scale = baseScale * gestureScale
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        geometry.size *= scale
        geometry.origin = CGPoint(
            x: center.x + (geometry.origin.x - center.x) * scale + baseOffset.width + panTranslation.width,
            y: center.y + (geometry.origin.y - center.y) * scale + baseOffset.height + panTranslation.height)
        return geometry
    }

    private func resetView() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            baseScale = 1
            baseOffset = .zero
        }
        gestureScale = 1
        panTranslation = .zero
    }

    @ViewBuilder
    private var viewControls: some View {
        if isTransformed {
            Button {
                resetView()
            } label: {
                Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(10)
        }
    }

    // MARK: Gestures

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                gestureScale = value
            }
            .onEnded { value in
                baseScale = min(max(baseScale * value, 0.45), 3)
                gestureScale = 1
            }
    }

    private func dragGesture(geometry: BoardGeometry) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                if drag == nil && !panning {
                    // First movement decides the mode: dragging a piece you
                    // can act with, or panning the board.
                    let startHex = geometry.hex(at: value.startLocation)
                    if match.isMyTurn,
                       let top = match.game.board.top(at: startHex),
                       selectablePieceIDs().contains(top.id) {
                        drag = DragState(pieceID: top.id, from: startHex, point: value.location)
                        selection = .board(pieceID: top.id, at: startHex)
                        return
                    }
                    panning = true
                }
                if drag != nil {
                    drag?.point = value.location
                } else {
                    panTranslation = value.translation
                }
            }
            .onEnded { value in
                if let active = drag {
                    let target = geometry.hex(at: value.location)
                    let moves = selectionMoves()[target] ?? []
                    let preferred = moves.first {
                        if case .move = $0 { return true }
                        if case .place = $0 { return true }
                        return false
                    } ?? moves.first
                    if let move = preferred {
                        match.play(move)
                    }
                    selection = .none
                    drag = nil
                    _ = active
                } else if panning {
                    baseOffset.width += value.translation.width
                    baseOffset.height += value.translation.height
                    panTranslation = .zero
                    panning = false
                }
            }
    }

    // MARK: Moves for current selection

    private var legalMoves: [Move] {
        match.isMyTurn ? match.currentLegalMoves() : []
    }

    /// Moves available from the current selection, keyed by destination.
    private func selectionMoves() -> [Hex: [Move]] {
        var result: [Hex: [Move]] = [:]
        switch selection {
        case .none:
            break
        case .hand(let kind):
            for move in legalMoves {
                if case .place(let piece, let at) = move, piece.kind == kind {
                    result[at, default: []].append(move)
                }
            }
        case .board(let pieceID, _):
            for move in legalMoves {
                switch move {
                case .move(let id, _, let to) where id == pieceID:
                    result[to, default: []].append(move)
                case .pillbugMove(_, let id, _, let to) where id == pieceID:
                    result[to, default: []].append(move)
                default:
                    break
                }
            }
        }
        return result
    }

    private func targetHexes() -> Set<Hex> {
        Set(selectionMoves().keys)
    }

    /// Pieces the local player can pick up this turn (own movers and pillbug
    /// throw victims, which may be either color).
    private func selectablePieceIDs() -> Set<String> {
        var ids: Set<String> = []
        for move in legalMoves {
            switch move {
            case .move(let id, _, _): ids.insert(id)
            case .pillbugMove(_, let id, _, _): ids.insert(id)
            default: break
            }
        }
        return ids
    }

    private func handleTap(at hex: Hex) {
        let moves = selectionMoves()[hex] ?? []
        // Prefer the piece's own movement; fall back to a pillbug throw.
        if let move = moves.first(where: { if case .move = $0 { return true }; return false }) ?? moves.first {
            match.play(move)
            selection = .none
            return
        }
        if let top = match.game.board.top(at: hex), selectablePieceIDs().contains(top.id) {
            if case .board(let selected, _) = selection, selected == top.id {
                selection = .none
            } else {
                selection = .board(pieceID: top.id, at: hex)
            }
            return
        }
        selection = .none
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, geometry: BoardGeometry, now: Date) {
        let board = match.game.board
        let theme = app.theme

        var selectedID: String?
        if case .board(let id, _) = selection { selectedID = id }

        var dimmed: Set<String> = []
        if match.isMyTurn {
            let selectable = selectablePieceIDs()
            for hex in board.occupiedHexes {
                if let top = board.top(at: hex), top.color == match.myColor,
                   !selectable.contains(top.id) {
                    dimmed.insert(top.id)
                }
            }
        }

        var params = BoardRenderParams(board: board, theme: theme)
        params.pieceStyle = app.pieceStyle
        params.material = app.material
        params.targets = targetHexes()
        params.selectedPieceID = selectedID
        params.dimmedPieceIDs = dimmed
        params.lastFrom = match.lastMoveOrigin
        params.lastTo = match.lastMoveDestination

        // Move animation: the destination's top piece glides in from its
        // origin (or pops in, for placements).
        var animating: (piece: Piece, t: CGFloat)?
        if let start = animationStart, let move = match.lastMove,
           let destination = move.destination, let piece = board.top(at: destination) {
            let t = CGFloat(min(max(now.timeIntervalSince(start) / Self.animationDuration, 0), 1))
            if t < 1 {
                params.hiddenTopAt = destination
                animating = (piece, t)
            }
        }

        // Dragging hides the piece at its origin; it follows the cursor.
        if let drag, let piece = board.top(at: drag.from) {
            params.hiddenTopAt = drag.from
            animating = nil
            BoardRenderer.draw(&context, geometry: geometry, params: params)
            BoardRenderer.drawFloatingPiece(
                &context, piece: piece, at: drag.point,
                size: geometry.size * 1.08, theme: theme, opacity: 0.92,
                style: app.pieceStyle, material: app.material)
            return
        }

        BoardRenderer.draw(&context, geometry: geometry, params: params)

        if let animating, let move = match.lastMove, let destination = move.destination {
            let t = animating.t
            let eased = 1 - pow(1 - t, 3)  // ease-out
            let destCenter = geometry.center(of: destination)
            switch move {
            case .move(_, let from, _), .pillbugMove(_, _, let from, _):
                let fromCenter = geometry.center(of: from)
                let point = CGPoint(
                    x: fromCenter.x + (destCenter.x - fromCenter.x) * eased,
                    y: fromCenter.y + (destCenter.y - fromCenter.y) * eased)
                let lift = 1 + 0.15 * sin(.pi * t)
                BoardRenderer.drawFloatingPiece(
                    &context, piece: animating.piece, at: point,
                    size: geometry.size * lift, theme: theme,
                    style: app.pieceStyle, material: app.material)
            case .place:
                BoardRenderer.drawFloatingPiece(
                    &context, piece: animating.piece, at: destCenter,
                    size: geometry.size * (0.4 + 0.6 * eased), theme: theme,
                    opacity: Double(0.3 + 0.7 * eased),
                    style: app.pieceStyle, material: app.material)
            case .pass:
                break
            }
        }
    }
}
