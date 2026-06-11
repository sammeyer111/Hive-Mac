import SwiftUI

/// Visual theme: background, accent, and board tile palette. All variants
/// keep a dark color scheme so the shared translucent styling works.
struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let swatch: String        // emoji shown in the picker
    let bgTop: Color
    let bgBottom: Color
    let accent: Color
    let tileLight: Color
    let tileLightStroke: Color
    let tileDark: Color
    let tileDarkStroke: Color

    static let honey = Theme(
        id: "honey", name: "Honey", swatch: "🍯",
        bgTop: Color(hex: "1A1A24"), bgBottom: Color(hex: "23232F"),
        accent: Color(hex: "FFB300"),
        tileLight: Color(hex: "F2E8C9"), tileLightStroke: Color(hex: "C9B98A"),
        tileDark: Color(hex: "3A3A45"), tileDarkStroke: Color(hex: "15151B"))

    static let midnight = Theme(
        id: "midnight", name: "Midnight", swatch: "🌊",
        bgTop: Color(hex: "0E1626"), bgBottom: Color(hex: "16233B"),
        accent: Color(hex: "5E9EFF"),
        tileLight: Color(hex: "DCE7F5"), tileLightStroke: Color(hex: "9FB4CE"),
        tileDark: Color(hex: "2E3D55"), tileDarkStroke: Color(hex: "0B1220"))

    static let forest = Theme(
        id: "forest", name: "Forest", swatch: "🌿",
        bgTop: Color(hex: "13211A"), bgBottom: Color(hex: "1B2E23"),
        accent: Color(hex: "7CB342"),
        tileLight: Color(hex: "EAE6C8"), tileLightStroke: Color(hex: "B5AE85"),
        tileDark: Color(hex: "32463A"), tileDarkStroke: Color(hex: "0E1A13"))

    static let plum = Theme(
        id: "plum", name: "Plum", swatch: "🍇",
        bgTop: Color(hex: "1F1426"), bgBottom: Color(hex: "2C1D38"),
        accent: Color(hex: "CE93D8"),
        tileLight: Color(hex: "EFE3F2"), tileLightStroke: Color(hex: "C0A8C8"),
        tileDark: Color(hex: "44324F"), tileDarkStroke: Color(hex: "170E1D"))

    static let all: [Theme] = [.honey, .midnight, .forest, .plum]

    static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? .honey
    }
}
