import SwiftUI
import HiveEngine

struct HistoryView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 20) {
            Text("Game History")
                .font(.largeTitle.bold())
                .padding(.top, 36)

            if app.store.games.isEmpty {
                Text("Finished games appear here — tap one to replay it move by move.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 30)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(app.store.games) { record in
                            row(record)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxWidth: 560, maxHeight: 420)
            }

            Button("Back") { app.route = .menu }
                .buttonStyle(SecondaryButtonStyle())

            Spacer()
        }
    }

    @ViewBuilder
    private func row(_ record: GameRecord) -> some View {
        Button {
            app.route = .replay(record)
        } label: {
            HStack(spacing: 12) {
                AvatarView(emoji: record.opponent.emoji, colorHex: record.opponent.colorHex, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("vs \(record.opponent.name)")
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(record.date.formatted(date: .abbreviated, time: .shortened)) • \(record.config.useExpansions ? "Full" : "Classic") • \(record.moves.count) moves")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(record.result)
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(resultColor(record.result).opacity(0.25), in: Capsule())
                    .foregroundStyle(resultColor(record.result))
                Image(systemName: "play.circle")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", role: .destructive) { app.store.deleteGame(record) }
        }
    }

    private func resultColor(_ result: String) -> Color {
        switch result {
        case "Win": return Color(hex: "43A047")
        case "Loss": return Color(hex: "E53935")
        default: return Color(hex: "9E9E9E")
        }
    }
}

// MARK: - Replay

struct ReplayView: View {
    @EnvironmentObject var app: AppState
    let record: GameRecord

    /// states[i] = position after i moves; index 0 is the empty board.
    @State private var states: [GameState] = []
    @State private var notations: [String] = []
    @State private var index = 0
    @State private var analysis: GameAnalysis?
    @State private var analysisDepth = AnalysisDepth.fast
    @StateObject private var analyzer = GameAnalyzer()

    enum AnalysisDepth: String, CaseIterable, Identifiable {
        case fast = "Fast", deep = "Deep"
        var id: String { rawValue }
        var seconds: Double { self == .fast ? 0.4 : 1.2 }
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            if analysis != nil { accuracyRow }

            HStack(spacing: 8) {
                if analysis != nil { evalBar }
                ReplayBoard(
                    state: currentState,
                    lastMove: index > 0 ? record.moves[index - 1] : nil,
                    bestMove: bestMoveForCurrent,
                    theme: app.theme,
                    pieceStyle: app.pieceStyle,
                    material: app.material)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                MoveListView(
                    notations: notations,
                    currentIndex: index > 0 ? index - 1 : nil,
                    classifications: analysis.map { $0.plies.map(\.classification) },
                    onSelect: { index = $0 + 1 })
                    .frame(width: 190)
            }
            .padding(.horizontal, 10)

            currentCaption
            if analysis != nil { evalGraph }
            controls
        }
        .onAppear(perform: prepare)
        .onChange(of: analyzer.analysis) { result in
            if let result {
                analysis = result
                app.store.attachAnalysis(result, to: record.id)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            AvatarView(emoji: record.opponent.emoji, colorHex: record.opponent.colorHex, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("vs \(record.opponent.name) — \(record.result)")
                    .font(.headline)
                Text("\(record.reason) • \(record.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            analyzeControl
            Button("Done") { analyzer.cancel(); app.route = .history }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
    }

    @ViewBuilder
    private var analyzeControl: some View {
        if analyzer.running {
            HStack(spacing: 8) {
                ProgressView(value: analyzer.progress).frame(width: 90)
                Text("\(Int(analyzer.progress * 100))%").font(.caption.monospaced())
                Button("Cancel") { analyzer.cancel() }.buttonStyle(SecondaryButtonStyle())
            }
        } else if analysis == nil {
            HStack(spacing: 8) {
                Picker("", selection: $analysisDepth) {
                    ForEach(AnalysisDepth.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 120)
                Button("Analyze") { analyzer.analyze(record: record, secondsPerMove: analysisDepth.seconds) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        } else {
            Label("Analyzed", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(Color(hex: "43A047"))
        }
    }

    private var accuracyRow: some View {
        HStack(spacing: 24) {
            accuracyPill("White", analysis?.whiteAccuracy ?? 0, mine: record.myColor == .white)
            accuracyPill("Black", analysis?.blackAccuracy ?? 0, mine: record.myColor == .black)
        }
    }

    private func accuracyPill(_ label: String, _ value: Double, mine: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.0f%%", value))
                .font(.system(.callout, design: .rounded).bold())
                .foregroundStyle(accuracyColor(value))
            if mine { Text("(you)").font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.white.opacity(0.06), in: Capsule())
    }

    private func accuracyColor(_ v: Double) -> Color {
        v >= 80 ? Color(hex: "43A047") : (v >= 60 ? Color(hex: "FBC02D") : Color(hex: "FB8C00"))
    }

    // MARK: Eval bar & graph

    private var currentEval: Int { analysis?.evalTimeline[safe: index] ?? 0 }

    private var evalBar: some View {
        GeometryReader { proxy in
            let wp = GameAnalyzer.winProb(currentEval)
            // White's share fills from the bottom (chess convention).
            VStack(spacing: 0) {
                Rectangle().fill(Color(hex: "2A2A30"))
                    .frame(height: proxy.size.height * (1 - wp))
                Rectangle().fill(Color(hex: "EDEDED"))
            }
            .overlay(alignment: .center) {
                Rectangle().fill(.white.opacity(0.3)).frame(height: 1)
            }
        }
        .frame(width: 16)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .help("White win probability: \(Int(GameAnalyzer.winProb(currentEval) * 100))%")
    }

    private var evalGraph: some View {
        let timeline = analysis?.evalTimeline ?? []
        return Canvas { context, size in
            guard timeline.count > 1 else { return }
            func point(_ i: Int) -> CGPoint {
                let x = size.width * CGFloat(i) / CGFloat(timeline.count - 1)
                let y = size.height * (1 - GameAnalyzer.winProb(timeline[i]))
                return CGPoint(x: x, y: y)
            }
            // Midline.
            var mid = Path()
            mid.move(to: CGPoint(x: 0, y: size.height / 2))
            mid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(mid, with: .color(.white.opacity(0.15)), lineWidth: 1)
            // Win-prob area.
            var line = Path()
            line.move(to: point(0))
            for i in 1..<timeline.count { line.addLine(to: point(i)) }
            context.stroke(line, with: .color(app.theme.accent), lineWidth: 2)
            // Current-position marker.
            let px = size.width * CGFloat(index) / CGFloat(timeline.count - 1)
            var marker = Path()
            marker.move(to: CGPoint(x: px, y: 0))
            marker.addLine(to: CGPoint(x: px, y: size.height))
            context.stroke(marker, with: .color(.white.opacity(0.6)), lineWidth: 1)
        }
        .frame(height: 46)
        .padding(.horizontal, 18)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            guard timeline.count > 1 else { return }
            let frac = max(0, min(1, value.location.x / max(1, graphWidth)))
            index = Int((frac * CGFloat(timeline.count - 1)).rounded())
        })
    }

    // Approximate graph width for tap mapping (window-relative is close enough).
    private var graphWidth: CGFloat { 860 - 36 }

    // MARK: Caption (per-move verdict)

    @ViewBuilder
    private var currentCaption: some View {
        if let ply = currentPly {
            HStack(spacing: 8) {
                Image(systemName: ply.classification.symbol)
                    .foregroundStyle(Color(hex: ply.classification.colorHex))
                Text("\(ply.playedNotation) — \(ply.classification.label)")
                    .font(.callout.bold())
                if !ply.wasBest {
                    Text("· best: \(ply.bestNotation)")
                        .font(.callout)
                        .foregroundStyle(Color(hex: "43A047"))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(.white.opacity(0.06), in: Capsule())
        }
    }

    /// The analysis of the move that produced the current position.
    private var currentPly: PlyAnalysis? {
        guard let analysis, index >= 1, index - 1 < analysis.plies.count else { return nil }
        return analysis.plies[index - 1]
    }

    /// Engine's best move for the position *before* the current one, shown as a
    /// green arrow when the played move wasn't best.
    private var bestMoveForCurrent: Move? {
        guard let ply = currentPly, !ply.wasBest else { return nil }
        return ply.bestMove
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 14) {
            controlButton("backward.end.fill") { index = 0 }.disabled(index == 0)
            controlButton("chevron.left") { index = max(0, index - 1) }.disabled(index == 0)
            Text("\(index) / \(record.moves.count)")
                .font(.system(.body, design: .monospaced).bold())
                .frame(width: 90)
            controlButton("chevron.right") { index = min(record.moves.count, index + 1) }
                .disabled(index >= record.moves.count)
            controlButton("forward.end.fill") { index = record.moves.count }
                .disabled(index >= record.moves.count)
        }
        .padding(.bottom, 16)
    }

    private var currentState: GameState {
        guard !states.isEmpty else {
            return GameState(config: record.config, startingPlayer: record.startingPlayer)
        }
        return states[min(index, states.count - 1)]
    }

    private func prepare() {
        var state = GameState(config: record.config, startingPlayer: record.startingPlayer)
        var all = [state]
        for move in record.moves {
            guard let next = Rules.applyUnchecked(move, to: state) else { break }
            state = next
            all.append(state)
        }
        states = all
        notations = Notation.list(
            moves: record.moves, config: record.config, startingPlayer: record.startingPlayer)
        analysis = record.analysis
        index = all.count - 1  // open at the final position
    }

    private func controlButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 40, height: 32)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Static board for replays: auto-fit, no interaction.
private struct ReplayBoard: View {
    let state: GameState
    let lastMove: Move?
    var bestMove: Move? = nil
    let theme: Theme
    let pieceStyle: PieceStyle
    let material: TileMaterial

    var body: some View {
        GeometryReader { proxy in
            // Include the best move's target so a suggested cell outside the
            // current hive still fits on screen.
            let hexes = Set(state.board.occupiedHexes)
                .union(bestMove?.destination.map { [$0] } ?? [])
            let geometry = BoardGeometry.fit(hexes: hexes, in: proxy.size)
            Canvas { context, _ in
                var params = BoardRenderParams(board: state.board, theme: theme)
                params.pieceStyle = pieceStyle
                params.material = material
                if let lastMove {
                    params.lastTo = lastMove.destination
                    switch lastMove {
                    case .move(_, let from, _), .pillbugMove(_, _, let from, _):
                        params.lastFrom = from
                    default:
                        break
                    }
                }
                if let bestMove {
                    params.bestTo = bestMove.destination
                    switch bestMove {
                    case .move(_, let from, _), .pillbugMove(_, _, let from, _):
                        params.bestFrom = from
                    default:
                        break
                    }
                }
                BoardRenderer.draw(&context, geometry: geometry, params: params)
            }
        }
        .padding(8)
    }
}
