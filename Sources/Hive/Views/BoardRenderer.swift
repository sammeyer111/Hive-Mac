import SwiftUI
import HiveEngine

/// Pointy-top hex layout math shared by the live board and replay views.
struct BoardGeometry {
    var size: CGFloat
    var origin: CGPoint

    static let sqrt3: CGFloat = 1.7320508075688772

    func center(of hex: Hex) -> CGPoint {
        let q = CGFloat(hex.q)
        let r = CGFloat(hex.r)
        let x: CGFloat = origin.x + size * (Self.sqrt3 * q + Self.sqrt3 / 2 * r)
        let y: CGFloat = origin.y + size * 1.5 * r
        return CGPoint(x: x, y: y)
    }

    func hex(at point: CGPoint) -> Hex {
        let x: CGFloat = (point.x - origin.x) / size
        let y: CGFloat = (point.y - origin.y) / size
        let q: CGFloat = Self.sqrt3 / 3 * x - y / 3
        let r: CGFloat = y * 2 / 3
        return Self.round(q: q, r: r)
    }

    static func round(q: CGFloat, r: CGFloat) -> Hex {
        let s = -q - r
        var rq = q.rounded()
        var rr = r.rounded()
        let rs = s.rounded()
        let dq = abs(rq - q)
        let dr = abs(rr - r)
        let ds = abs(rs - s)
        if dq > dr && dq > ds {
            rq = -rr - rs
        } else if dr > ds {
            rr = -rq - rs
        }
        return Hex(Int(rq), Int(rr))
    }

    /// Auto-fit geometry for a set of hexes inside `size`, with margin.
    static func fit(hexes: Set<Hex>, in size: CGSize, maxScale: CGFloat = 46) -> BoardGeometry {
        var hexes = hexes
        if hexes.isEmpty { hexes.insert(Hex(0, 0)) }
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        let unit = BoardGeometry(size: 1, origin: .zero)
        for hex in hexes {
            let c = unit.center(of: hex)
            minX = min(minX, c.x); maxX = max(maxX, c.x)
            minY = min(minY, c.y); maxY = max(maxY, c.y)
        }
        let widthUnits = (maxX - minX) + 2 * sqrt3
        let heightUnits = (maxY - minY) + 4
        let scale = min(maxScale, min(size.width / widthUnits, size.height / heightUnits))
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        return BoardGeometry(
            size: scale,
            origin: CGPoint(
                x: size.width / 2 - centerX * scale,
                y: size.height / 2 - centerY * scale))
    }
}

/// Everything needed to paint one frame of a board.
struct BoardRenderParams {
    var board: Board
    var theme: Theme
    var pieceStyle: PieceStyle = .modern
    var material: TileMaterial = .flat
    var targets: Set<Hex> = []
    var selectedPieceID: String?
    var dimmedPieceIDs: Set<String> = []
    var lastFrom: Hex?
    var lastTo: Hex?
    /// Engine's recommended move (drawn as a green arrow / ring).
    var bestFrom: Hex?
    var bestTo: Hex?
    /// Hex whose top piece is being drawn elsewhere (drag/animation).
    var hiddenTopAt: Hex?
}

/// Stateless board painter shared by the live game and replay screens.
enum BoardRenderer {

    static func hexPath(center: CGPoint, size: CGFloat) -> Path {
        var path = Path()
        for i in 0..<6 {
            let angle = CGFloat.pi / 180 * (60 * CGFloat(i) - 30)
            let point = CGPoint(x: center.x + size * cos(angle), y: center.y + size * sin(angle))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    static func draw(_ context: inout GraphicsContext, geometry: BoardGeometry, params: BoardRenderParams) {
        let board = params.board
        let highlight = Color(hex: "00C2A8")

        // Target highlights first (under pieces, so beetle climbs show).
        for hex in params.targets {
            let path = hexPath(center: geometry.center(of: hex), size: geometry.size * 0.92)
            if !board.isOccupied(hex) {
                context.fill(path, with: .color(highlight.opacity(0.25)))
            }
            context.stroke(path, with: .color(highlight), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
        }

        for hex in board.occupiedHexes.sorted(by: { ($0.r, $0.q) < ($1.r, $1.q) }) {
            let height = board.height(at: hex)
            guard height > 0 else { continue }
            let baseCenter = geometry.center(of: hex)
            for level in 0..<height {
                guard level >= height - 2 else { continue }  // draw at most top two
                let isTop = level == height - 1
                if isTop && params.hiddenTopAt == hex { continue }
                let piece = board.stack(at: hex)[level]
                let offset = CGFloat(height - 1 - level) * geometry.size * 0.12
                let center = CGPoint(x: baseCenter.x - offset, y: baseCenter.y - offset)
                let path = hexPath(center: center, size: geometry.size * 0.92)

                context.opacity = isTop ? 1 : 0.75
                fillTile(&context, path: path, center: center, size: geometry.size,
                         isWhitePiece: piece.color == .white,
                         theme: params.theme, material: params.material)
                context.opacity = 1

                var strokeColor = tileStroke(
                    isWhitePiece: piece.color == .white,
                    theme: params.theme, material: params.material)
                var lineWidth: CGFloat = 1.5
                if isTop, params.selectedPieceID == piece.id {
                    strokeColor = params.theme.accent
                    lineWidth = 3
                } else if isTop && params.targets.contains(hex) {
                    strokeColor = highlight
                    lineWidth = 2.5
                } else if isTop && params.lastTo == hex {
                    strokeColor = Color(hex: "5E9EFF")
                    lineWidth = 2.5
                }
                context.stroke(path, with: .color(strokeColor), lineWidth: lineWidth)

                if isTop {
                    let dimmed = params.dimmedPieceIDs.contains(piece.id)
                    context.opacity = dimmed ? 0.45 : 1
                    drawGlyph(&context, piece: piece, at: center,
                              size: geometry.size, style: params.pieceStyle)
                    context.opacity = 1
                    if height > 1 {
                        let badge = CGPoint(
                            x: center.x + geometry.size * 0.5,
                            y: center.y - geometry.size * 0.55)
                        context.fill(
                            Path(ellipseIn: CGRect(x: badge.x - 9, y: badge.y - 9, width: 18, height: 18)),
                            with: .color(params.theme.accent))
                        context.draw(
                            Text("\(height)").font(.system(size: 11, weight: .black)).foregroundColor(.black),
                            at: badge)
                    }
                }
            }
        }

        // Best-move arrow first (under the played-move arrow), green.
        let green = Color(hex: "43A047")
        if let to = params.bestTo {
            if let from = params.bestFrom, from != to {
                drawArrow(&context, from: geometry.center(of: from), to: geometry.center(of: to),
                          tileSize: geometry.size, color: green.opacity(0.8))
            } else {
                // Placement suggestion: ring the target.
                let ring = hexPath(center: geometry.center(of: to), size: geometry.size * 0.95)
                context.stroke(ring, with: .color(green), style: StrokeStyle(lineWidth: 3, dash: [6, 3]))
            }
        }

        // Last-move arrow, drawn over the tiles.
        if let from = params.lastFrom, let to = params.lastTo, from != to {
            drawArrow(&context, from: geometry.center(of: from), to: geometry.center(of: to),
                      tileSize: geometry.size, color: Color(hex: "5E9EFF").opacity(0.65))
            // Mark the vacated hex faintly.
            let origin = hexPath(center: geometry.center(of: from), size: geometry.size * 0.6)
            context.stroke(origin, with: .color(Color(hex: "5E9EFF").opacity(0.45)), lineWidth: 1.5)
        }
    }

    private static func drawArrow(_ context: inout GraphicsContext, from: CGPoint, to: CGPoint, tileSize: CGFloat, color: Color) {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max(sqrt(dx * dx + dy * dy), 1)
        let ux = dx / length, uy = dy / length
        // Stop short of both tile centers.
        let start = CGPoint(x: from.x + ux * tileSize * 0.55, y: from.y + uy * tileSize * 0.55)
        let end = CGPoint(x: to.x - ux * tileSize * 0.72, y: to.y - uy * tileSize * 0.72)

        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))

        let headSize = tileSize * 0.3
        var head = Path()
        head.move(to: CGPoint(x: end.x + ux * headSize, y: end.y + uy * headSize))
        head.addLine(to: CGPoint(x: end.x - uy * headSize * 0.55, y: end.y + ux * headSize * 0.55))
        head.addLine(to: CGPoint(x: end.x + uy * headSize * 0.55, y: end.y - ux * headSize * 0.55))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }

    /// A single free-floating tile (dragged or animating piece).
    static func drawFloatingPiece(_ context: inout GraphicsContext, piece: Piece, at center: CGPoint,
                                  size: CGFloat, theme: Theme, opacity: Double = 1,
                                  style: PieceStyle = .modern, material: TileMaterial = .flat) {
        let path = hexPath(center: center, size: size * 0.92)
        context.opacity = opacity
        fillTile(&context, path: path, center: center, size: size,
                 isWhitePiece: piece.color == .white, theme: theme, material: material)
        context.stroke(path, with: .color(theme.accent), lineWidth: 2.5)
        drawGlyph(&context, piece: piece, at: center, size: size, style: style)
        context.opacity = 1
    }

    // MARK: Glyphs

    private static func drawGlyph(_ context: inout GraphicsContext, piece: Piece,
                                  at center: CGPoint, size: CGFloat, style: PieceStyle) {
        if let image = PieceArt.shared.image(kind: piece.kind, color: piece.color, style: style) {
            let side = size * 1.18
            context.draw(image, in: CGRect(
                x: center.x - side / 2, y: center.y - side / 2, width: side, height: side))
        } else {
            context.draw(Text(piece.kind.emoji).font(.system(size: size * 0.85)), at: center)
        }
    }

    // MARK: Materials

    private static func tileStroke(isWhitePiece: Bool, theme: Theme, material: TileMaterial) -> Color {
        switch material {
        case .flat:
            return isWhitePiece ? theme.tileLightStroke : theme.tileDarkStroke
        case .wood:
            return isWhitePiece ? Color(hex: "8A6A45") : Color(hex: "3E2A18")
        case .marble:
            return isWhitePiece ? Color(hex: "B9B4A9") : Color(hex: "15151A")
        case .metal:
            return isWhitePiece ? Color(hex: "8E939C") : Color(hex: "1F2228")
        }
    }

    /// Fills a hex tile in the chosen surface material. Patterns are drawn
    /// clipped to the tile so they never bleed.
    private static func fillTile(_ context: inout GraphicsContext, path: Path,
                                 center: CGPoint, size: CGFloat,
                                 isWhitePiece: Bool, theme: Theme, material: TileMaterial) {
        let top = CGPoint(x: center.x, y: center.y - size)
        let bottom = CGPoint(x: center.x, y: center.y + size)
        switch material {
        case .flat:
            context.fill(path, with: .color(isWhitePiece ? theme.tileLight : theme.tileDark))

        case .wood:
            let colors = isWhitePiece
                ? [Color(hex: "DDBE92"), Color(hex: "C49A6C")]
                : [Color(hex: "7A5230"), Color(hex: "55381F")]
            context.fill(path, with: .linearGradient(
                Gradient(colors: colors), startPoint: top, endPoint: bottom))
            var grain = context
            grain.clip(to: path)
            let grainColor = (isWhitePiece ? Color(hex: "8A6A45") : Color(hex: "2E1E10")).opacity(0.35)
            for (i, offset) in [-0.42, -0.05, 0.34].enumerated() {
                var line = Path()
                let y = center.y + size * offset
                line.move(to: CGPoint(x: center.x - size, y: y))
                line.addQuadCurve(
                    to: CGPoint(x: center.x + size, y: y + size * 0.08),
                    control: CGPoint(x: center.x + size * (i % 2 == 0 ? -0.1 : 0.2),
                                     y: y + size * (i % 2 == 0 ? 0.16 : -0.14)))
                grain.stroke(line, with: .color(grainColor), lineWidth: size * 0.045)
            }

        case .marble:
            let colors = isWhitePiece
                ? [Color(hex: "F2F0EA"), Color(hex: "D9D4CA")]
                : [Color(hex: "3C3C44"), Color(hex: "232329")]
            context.fill(path, with: .linearGradient(
                Gradient(colors: colors), startPoint: top, endPoint: bottom))
            var veins = context
            veins.clip(to: path)
            let veinColor = (isWhitePiece ? Color(hex: "9B958A") : Color(hex: "8E8E9A")).opacity(0.3)
            for (dx, dy) in [(-0.7, -0.9), (0.2, -0.5)] {
                var vein = Path()
                vein.move(to: CGPoint(x: center.x + size * dx, y: center.y + size * dy))
                vein.addCurve(
                    to: CGPoint(x: center.x + size * (dx + 0.9), y: center.y + size * (dy + 1.6)),
                    control1: CGPoint(x: center.x + size * (dx + 0.6), y: center.y + size * (dy + 0.3)),
                    control2: CGPoint(x: center.x + size * (dx - 0.1), y: center.y + size * (dy + 1.1)))
                veins.stroke(vein, with: .color(veinColor), lineWidth: size * 0.035)
            }

        case .metal:
            let colors = isWhitePiece
                ? [Color(hex: "EDEFF3"), Color(hex: "AEB4BE"), Color(hex: "D6DAE1")]
                : [Color(hex: "62676F"), Color(hex: "33373D"), Color(hex: "4A4E55")]
            context.fill(path, with: .linearGradient(
                Gradient(colors: colors),
                startPoint: CGPoint(x: center.x - size, y: center.y - size),
                endPoint: CGPoint(x: center.x + size, y: center.y + size)))
            var sheen = context
            sheen.clip(to: path)
            var band = Path()
            band.move(to: CGPoint(x: center.x - size * 1.1, y: center.y + size * 0.55))
            band.addLine(to: CGPoint(x: center.x + size * 0.55, y: center.y - size * 1.1))
            sheen.stroke(band, with: .color(.white.opacity(isWhitePiece ? 0.4 : 0.18)),
                         lineWidth: size * 0.22)
        }
    }
}
