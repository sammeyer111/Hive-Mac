import SwiftUI
import AppKit
import HiveEngine

/// How piece glyphs are drawn on the tiles.
enum PieceStyle: String, CaseIterable, Identifiable {
    case modern    // emoji (the original look)
    case classic   // the colored icons from the physical game
    case carbon    // solid silhouettes: black for White's pieces, white for Black's

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .modern: return "Modern"
        case .classic: return "Classic"
        case .carbon: return "Carbon"
        }
    }
}

/// Tile surface finish; independent of the piece style.
enum TileMaterial: String, CaseIterable, Identifiable {
    case flat      // theme's flat colors
    case wood
    case marble
    case metal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flat: return "Flat"
        case .wood: return "Wood"
        case .marble: return "Marble"
        case .metal: return "Metal"
        }
    }
}

/// `Hive --selftest-art`: verifies the piece icons resolve from the app
/// bundle itself (not the dev project folder) on whatever machine runs it.
enum ArtSelfTest {
    static func runAndExit() {
        var loaded = 0, missing = 0
        for kind in PieceKind.allCases {
            for (style, color) in [(PieceStyle.classic, PlayerColor.white),
                                   (.carbon, .white), (.carbon, .black)] {
                if PieceArt.shared.image(kind: kind, color: color, style: style) != nil {
                    loaded += 1
                } else {
                    missing += 1
                }
            }
        }
        print("art: \(loaded) icons loaded, \(missing) missing (exe: \(Bundle.main.bundlePath))")
        print(missing == 0 ? "selftest: PASS — piece icons embedded"
                           : "selftest: FAIL — icons not found in app bundle")
        exit(missing == 0 ? 0 : 1)
    }
}

/// Loads and caches the piece icon images bundled with the app.
final class PieceArt {
    static let shared = PieceArt()
    private var cache: [String: Image?] = [:]
    private let lock = NSLock()

    /// The SPM resource bundle, resolved only from locations that travel
    /// with the app: Contents/Resources inside the .app, or next to the bare
    /// binary for `swift run`. Deliberately NOT Bundle.module — its generated
    /// accessor falls back to the build machine's absolute project path (so
    /// icons silently load from the project folder) and calls fatalError on
    /// a Mac where neither exists. Missing bundle here just means emoji.
    private static let resourceBundle: Bundle? = {
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
        ]
        for candidate in candidates {
            guard let base = candidate else { continue }
            let url = base.appendingPathComponent("Hive_Hive.bundle")
            if let bundle = Bundle(url: url) { return bundle }
        }
        netlog("art: piece icon bundle not found — using emoji pieces")
        return nil
    }()

    /// Glyph image for a piece, or nil when the style draws emoji (modern)
    /// or the asset is missing (renderer falls back to emoji).
    func image(kind: PieceKind, color: PlayerColor, style: PieceStyle) -> Image? {
        let file: String
        let subdirectory: String
        switch style {
        case .modern:
            return nil
        case .classic:
            file = kind.rawValue          // same colored icon for both players
            subdirectory = "Pieces/classic"
        case .carbon:
            // Black silhouettes for White's pieces, white for Black's.
            file = "\(kind.rawValue)-\(color == .white ? "dark" : "light")"
            subdirectory = "Pieces/carbon"
        }
        let key = "\(subdirectory)/\(file)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        var loaded: Image?
        if let url = Self.resourceBundle?.url(forResource: file, withExtension: "png", subdirectory: subdirectory),
           let nsImage = NSImage(contentsOf: url) {
            loaded = Image(nsImage: nsImage)
        } else {
            netlog("art: missing piece asset \(key)")
        }
        cache[key] = loaded
        return loaded
    }
}
