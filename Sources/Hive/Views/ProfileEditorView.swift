import SwiftUI

struct ProfileEditorView: View {
    @EnvironmentObject var app: AppState
    let isFirstRun: Bool

    @State private var name = ""
    @State private var emoji = "🐝"
    @State private var colorHex = "FFB300"
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 24) {
            Text(isFirstRun ? "Create your profile" : "Edit profile")
                .font(.largeTitle.bold())
                .padding(.top, 30)

            AvatarView(emoji: emoji, colorHex: colorHex, size: 96)

            TextField("Your name", text: $name)
                .onChange(of: name) { value in
                    if value.count > 20 { name = String(value.prefix(20)) }
                }
                .textFieldStyle(.plain)
                .font(.title2)
                .multilineTextAlignment(.center)
                .padding(12)
                .frame(width: 280)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 10) {
                Text("AVATAR").font(.caption.bold()).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 8), spacing: 8) {
                    ForEach(Profile.avatarEmojis, id: \.self) { e in
                        Button {
                            emoji = e
                        } label: {
                            Text(e)
                                .font(.system(size: 24))
                                .frame(width: 42, height: 42)
                                .background(
                                    emoji == e ? Color(hex: colorHex).opacity(0.45) : .white.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("COLOR").font(.caption.bold()).foregroundStyle(.secondary)
                    .padding(.top, 6)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 6), spacing: 8) {
                    ForEach(Profile.accentColors, id: \.self) { hex in
                        Button {
                            colorHex = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 30, height: 30)
                                .overlay(
                                    Circle().stroke(.white, lineWidth: colorHex == hex ? 2.5 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("APP THEME").font(.caption.bold()).foregroundStyle(.secondary)
                    .padding(.top, 6)
                HStack(spacing: 10) {
                    ForEach(Theme.all) { theme in
                        Button {
                            app.themeID = theme.id
                        } label: {
                            VStack(spacing: 4) {
                                ZStack {
                                    Circle()
                                        .fill(LinearGradient(
                                            colors: [theme.bgTop, theme.accent],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 34, height: 34)
                                    Text(theme.swatch).font(.system(size: 15))
                                }
                                .overlay(
                                    Circle().stroke(.white, lineWidth: app.themeID == theme.id ? 2.5 : 0))
                                Text(theme.name)
                                    .font(.caption2)
                                    .foregroundStyle(app.themeID == theme.id ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PIECE STYLE").font(.caption.bold()).foregroundStyle(.secondary)
                        Picker("", selection: $app.pieceStyle) {
                            ForEach(PieceStyle.allCases) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TILE MATERIAL").font(.caption.bold()).foregroundStyle(.secondary)
                        Picker("", selection: $app.material) {
                            ForEach(TileMaterial.allCases) { material in
                                Text(material.displayName).tag(material)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                .padding(.top, 6)

                Toggle(isOn: $app.soundsEnabled) {
                    Text("SOUND EFFECTS").font(.caption.bold()).foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.top, 10)

                Toggle(isOn: $app.musicEnabled) {
                    Text("MUSIC").font(.caption.bold()).foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.top, 4)
            }
            .frame(width: 440)

            HStack(spacing: 14) {
                if !isFirstRun {
                    Button("Cancel") { app.route = .menu }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Button("Save") {
                    var profile = app.store.profile ?? Profile()
                    profile.name = name.trimmingCharacters(in: .whitespaces)
                    profile.emoji = emoji
                    profile.colorHex = colorHex
                    app.store.save(profile: profile)
                    app.route = .menu
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.bottom, 30)

            Spacer()
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let profile = app.store.profile {
                name = profile.name
                emoji = profile.emoji
                colorHex = profile.colorHex
            }
        }
    }
}
