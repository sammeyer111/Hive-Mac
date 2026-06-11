import SwiftUI
import HiveEngine

/// A native, scrollable settings popup (grouped Form) holding the profile,
/// board appearance, and audio options. On first run it stands in as the
/// onboarding screen and requires a name before continuing.
struct SettingsView: View {
    @EnvironmentObject var app: AppState
    var isFirstRun: Bool = false

    @State private var name = ""
    @State private var emoji = "🐝"
    @State private var colorHex = "FFB300"
    @State private var loaded = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isFirstRun ? "Welcome to Hive" : "Settings")
                    .font(.title2.bold())
                Spacer()
                if !isFirstRun {
                    Button {
                        save()
                        app.showSettings = false
                    } label: {
                        Text("Done").font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)

            Form {
                profileSection
                appearanceSection
                audioSection
            }
            .formStyle(.grouped)

            if isFirstRun {
                Button("Get Started") { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(trimmedName.isEmpty)
                    .padding(.vertical, 16)
            }
        }
        .frame(width: 480, height: isFirstRun ? 640 : 560)
        .background(.ultraThickMaterial)
        .onAppear(perform: loadOnce)
    }

    // MARK: Sections

    private var profileSection: some View {
        Section("Profile") {
            HStack(spacing: 14) {
                AvatarView(emoji: emoji, colorHex: colorHex, size: 56)
                TextField("Your name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { value in
                        if value.count > 20 { name = String(value.prefix(20)) }
                    }
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text("Avatar").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(40)), count: 8), spacing: 8) {
                    ForEach(Profile.avatarEmojis, id: \.self) { e in
                        Button { emoji = e } label: {
                            Text(e)
                                .font(.system(size: 22))
                                .frame(width: 38, height: 38)
                                .background(
                                    emoji == e ? Color(hex: colorHex).opacity(0.45) : .white.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text("Color").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(40)), count: 6), spacing: 8) {
                    ForEach(Profile.accentColors, id: \.self) { hex in
                        Button { colorHex = hex } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 28, height: 28)
                                .overlay(Circle().stroke(.white, lineWidth: colorHex == hex ? 2.5 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var appearanceSection: some View {
        Section("Board") {
            Picker("App theme", selection: $app.themeID) {
                ForEach(Theme.all) { theme in
                    Text("\(theme.swatch)  \(theme.name)").tag(theme.id)
                }
            }
            Picker("Piece style", selection: $app.pieceStyle) {
                ForEach(PieceStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            Picker("Tile material", selection: $app.material) {
                ForEach(TileMaterial.allCases) { material in
                    Text(material.displayName).tag(material)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Preview").font(.caption).foregroundStyle(.secondary)
                TilePreview(style: app.pieceStyle, material: app.material, theme: app.theme)
            }
            .padding(.vertical, 4)
        }
    }

    private var audioSection: some View {
        Section("Audio") {
            volumeRow("Master", icon: "speaker.wave.3.fill", value: $app.masterVolume)
            volumeRow("Sound effects", icon: "speaker.wave.2.fill", value: $app.sfxVolume)
            volumeRow("Music", icon: "music.note", value: $app.musicVolume)
        }
    }

    private func volumeRow(_ label: String, icon: String, value: Binding<Double>) -> some View {
        HStack(spacing: 12) {
            Label(label, systemImage: icon)
                .frame(width: 130, alignment: .leading)
            Slider(value: value, in: 0...1)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: Load / save

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        if let profile = app.store.profile {
            name = profile.name
            emoji = profile.emoji
            colorHex = profile.colorHex
        }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        var profile = app.store.profile ?? Profile()
        profile.name = trimmedName
        profile.emoji = emoji
        profile.colorHex = colorHex
        app.store.save(profile: profile)
        app.showSettings = false
    }
}

/// Live sample of how pieces look with the current style/material/theme,
/// drawn with the exact same renderer the board uses.
struct TilePreview: View {
    let style: PieceStyle
    let material: TileMaterial
    let theme: Theme

    var body: some View {
        Canvas { context, size in
            let tile = min(size.width / 2.6, size.height * 0.46)
            let y = size.height / 2
            BoardRenderer.drawFloatingPiece(
                &context, piece: Piece(kind: .queen, color: .white, index: 1),
                at: CGPoint(x: size.width * 0.34, y: y), size: tile,
                theme: theme, style: style, material: material)
            BoardRenderer.drawFloatingPiece(
                &context, piece: Piece(kind: .ant, color: .black, index: 1),
                at: CGPoint(x: size.width * 0.66, y: y), size: tile,
                theme: theme, style: style, material: material)
        }
        .frame(height: 96)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [theme.bgTop, theme.bgBottom],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08)))
    }
}
