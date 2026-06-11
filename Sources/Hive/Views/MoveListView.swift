import SwiftUI

/// Scrolling list of moves in standard notation, shared by the in-game
/// panel and the replay screen.
struct MoveListView: View {
    let notations: [String]
    /// Replay: index of the move currently shown (highlights + taps enabled).
    var currentIndex: Int? = nil
    /// Optional per-move classification badge (analysis).
    var classifications: [MoveClass]? = nil
    var onSelect: ((Int) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MOVES")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
            if notations.isEmpty {
                Text("No moves yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
            }
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(notations.indices, id: \.self) { index in
                            row(index)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onChange(of: notations.count) { count in
                    guard currentIndex == nil, count > 0 else { return }
                    withAnimation { scroller.scrollTo(count - 1, anchor: .bottom) }
                }
                .onChange(of: currentIndex) { index in
                    if let index, index >= 0 {
                        withAnimation { scroller.scrollTo(index, anchor: .center) }
                    }
                }
            }
        }
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func row(_ index: Int) -> some View {
        let highlighted = currentIndex == index
        HStack(spacing: 6) {
            Text("\(index + 1).")
                .foregroundStyle(.tertiary)
                .frame(width: 26, alignment: .trailing)
            Text(notations[index])
                .foregroundStyle(highlighted ? .primary : .secondary)
            Spacer(minLength: 0)
            if let classifications, index < classifications.count {
                let c = classifications[index]
                Image(systemName: c.symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(hex: c.colorHex))
            }
        }
        .font(.system(.caption, design: .monospaced).weight(highlighted ? .bold : .regular))
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            highlighted ? Color.white.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onSelect?(index) }
    }
}
