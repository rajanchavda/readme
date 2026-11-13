import SwiftUI

/// The shelf's search: a magnifier in the corner that opens into a field for a title or an author.
struct ShelfSearchField: View {
    @ObservedObject var search: ShelfSearch
    /// Return in the field.
    let onSubmit: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if search.isOpen {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(ShelfStyle.muted)
                    .accessibilityHidden(true)
                TextField("Title or author", text: $search.query)
                    .textFieldStyle(.plain)
                    .font(ShelfStyle.body(16))
                    .foregroundStyle(ShelfStyle.text)
                    .focused($focused)
                    .onSubmit(onSubmit)
                    .onAppear(perform: takeKeyboard)
                    .accessibilityLabel("Search the library")
                if !search.query.isEmpty {
                    Button { search.close() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(ShelfStyle.muted)
                    }
                    .buttonStyle(.plain)
                    .help("Clear the search")
                    .accessibilityLabel("Clear the search")
                }
            } else {
                Button { search.open() } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundStyle(ShelfStyle.soft)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Search the library (⌘F)")
                .accessibilityLabel("Search")
            }
        }
        .padding(.horizontal, search.isOpen ? 12 : 0)
        .frame(width: search.isOpen ? 240 : nil, height: 30)
        .background {
            if search.isOpen {
                Capsule().fill(Color(red: 0x24 / 255, green: 0x1F / 255, blue: 0x1A / 255))
                Capsule().strokeBorder(ShelfStyle.text.opacity(0.1))
            }
        }
        .animation(reduceMotion ? nil : ShelfStyle.lift, value: search.isOpen)
        .onChange(of: search.focusRequest) { takeKeyboard() }
        // Clicking away from an empty field folds it back to its icon.
        .onChange(of: focused) { _, isFocused in
            if !isFocused && !search.isActive { search.close() }
        }
    }

    /// Puts the keyboard in the field. Asked for as the field is first put on screen, focus is dropped,
    /// so it's asked for once the field is there, and again once it has finished opening.
    private func takeKeyboard() {
        Task { @MainActor in
            await Task.yield()
            focused = true
            try? await Task.sleep(for: .milliseconds(250))
            if search.isOpen && !focused { focused = true }
        }
    }
}
