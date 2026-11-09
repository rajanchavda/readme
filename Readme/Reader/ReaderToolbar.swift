import AppKit
import Observation
import SwiftUI

/// What the toolbar shows and what it changes. The window owns it and hears about changes.
@MainActor
@Observable
final class ReaderToolbarModel {
    var settings: ReaderSettings {
        didSet { if settings != oldValue { onSettingsChange?(settings) } }
    }
    /// The theme on the page, which picks the toolbar's own colours.
    var theme = Theme.paper
    var timeLeft: String?
    var isAwake = false
    var isFullscreen = false

    @ObservationIgnored var onSettingsChange: ((ReaderSettings) -> Void)?
    @ObservationIgnored var onCommand: ((ReaderCommand) -> Void)?
    /// Hears the pointer come onto the toolbar and leave it. While it's there, the toolbar stays awake.
    @ObservationIgnored var onHover: ((Bool) -> Void)?

    init(settings: ReaderSettings) {
        self.settings = settings
    }
}

/// How much of the chapter is left to read, as the toolbar says it.
enum TimeLeft {
    static func text(minutes: Double) -> String {
        guard minutes >= 1 else { return "Under a minute left in chapter" }
        let whole = Int(minutes.rounded())
        guard whole >= 60 else { return "\(whole) min left in chapter" }
        let hours = whole / 60, rest = whole % 60
        return rest == 0 ? "\(hours) hr left in chapter" : "\(hours) hr \(rest) min left in chapter"
    }
}

/// The quiet toolbar from `docs/mockups/open-book-v2.html`: a small blurred bar at the top of the
/// desk that eases in when the mouse moves and out when it rests.
struct ReaderToolbar: View {
    @Bindable var model: ReaderToolbarModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ThemeChoice.allCases, id: \.self) { choice in
                Button(Self.name(of: choice)) { model.settings.theme = choice }
                    .buttonStyle(ChromeButtonStyle(isOn: model.settings.theme == choice))
            }
            textMenu
            Button("A\u{2212}") { model.onCommand?(.smallerText) }
                .buttonStyle(ChromeButtonStyle())
                .help("Smaller text")
                .disabled(model.settings.fontSize <= ReaderCommand.fontSizes.lowerBound)
            Button("A+") { model.onCommand?(.biggerText) }
                .buttonStyle(ChromeButtonStyle())
                .help("Bigger text")
                .disabled(model.settings.fontSize >= ReaderCommand.fontSizes.upperBound)
            if let timeLeft = model.timeLeft {
                Text(timeLeft)
                    .opacity(0.7)
                    .padding(.horizontal, 9)
            }
            iconButton("list.bullet", help: "Contents", command: .toggleTOC)
            iconButton("books.vertical", help: "Library", command: .showLibrary)
            iconButton(
                model.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                help: model.isFullscreen ? "Exit fullscreen" : "Fullscreen", command: .toggleFullscreen)
        }
        .font(.system(size: 12))
        .foregroundStyle(Color(nsColor: Self.ink(model.theme)))
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: Self.chrome(model.theme)))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
                .animation(.easeOut(duration: 0.2), value: model.theme)
        }
        // A background reaches into the safe area under the title bar unless it's clipped.
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .fixedSize()
        .onHover { model.onHover?($0) }
        .opacity(model.isAwake ? 1 : 0)
        .offset(y: model.isAwake ? 0 : -6)
        .animation(.easeOut(duration: 0.2), value: model.isAwake)
        .allowsHitTesting(model.isAwake)
        .ignoresSafeArea()
    }

    /// Fonts and line width share one menu, to keep the bar short.
    private var textMenu: some View {
        Menu {
            Picker("Font", selection: $model.settings.font) {
                ForEach(BookFont.allCases, id: \.self) { Text(Self.name(of: $0)).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Line Width", selection: $model.settings.lineWidth) {
                ForEach(LineWidth.allCases, id: \.self) { Text(Self.name(of: $0)).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text("Aa")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ChromeButtonStyle())
        .fixedSize()
        .help("Font and line width")
    }

    private func iconButton(_ symbol: String, help: String, command: ReaderCommand) -> some View {
        Button {
            model.onCommand?(command)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(height: 15)
        }
        .buttonStyle(ChromeButtonStyle())
        .help(help)
    }

    // MARK: Words and colours

    static func name(of choice: ThemeChoice) -> String {
        switch choice {
        case .auto: "Auto"
        case .paper: "Paper"
        case .sepia: "Sepia"
        case .night: "Night"
        }
    }

    static func name(of font: BookFont) -> String {
        switch font {
        case .ebGaramond: "EB Garamond"
        case .literata: "Literata"
        case .newYork: "New York"
        }
    }

    static func name(of width: LineWidth) -> String {
        switch width {
        case .narrow: "Narrow"
        case .regular: "Regular"
        case .wide: "Wide"
        }
    }

    static func chrome(_ theme: Theme) -> NSColor {
        theme == .night
            ? NSColor(srgbRed: 70 / 255, green: 70 / 255, blue: 74 / 255, alpha: 0.72)
            : NSColor(srgbRed: 40 / 255, green: 34 / 255, blue: 28 / 255, alpha: 0.72)
    }

    static func ink(_ theme: Theme) -> NSColor {
        theme == .night
            ? NSColor(srgbRed: 0xE6 / 255, green: 0xE3 / 255, blue: 0xDB / 255, alpha: 1)
            : NSColor(srgbRed: 0xF5 / 255, green: 0xEF / 255, blue: 0xE2 / 255, alpha: 1)
    }
}

/// The mockup's buttons: no border, a faint fill on hover and a stronger one when chosen.
private struct ChromeButtonStyle: ButtonStyle {
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        ChromeButton(configuration: configuration, isOn: isOn)
    }

    private struct ChromeButton: View {
        let configuration: ButtonStyleConfiguration
        let isOn: Bool
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.vertical, 3)
                .padding(.horizontal, 9)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(fill)))
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovered = $0 }
        }

        private var fill: Double {
            if isOn || configuration.isPressed { return 0.22 }
            return isHovered && isEnabled ? 0.14 : 0
        }
    }
}

/// Hosts the toolbar, and lets clicks through to the book while it's asleep.
final class ReaderToolbarHost: NSHostingView<ReaderToolbar> {
    private let model: ReaderToolbarModel

    init(model: ReaderToolbarModel) {
        self.model = model
        super.init(rootView: ReaderToolbar(model: model))
        // Placed by the window, 12 points from the top as in the mockup, wherever the title bar is.
        safeAreaRegions = []
    }

    @available(*, unavailable)
    required init(rootView: ReaderToolbar) {
        fatalError("ReaderToolbarHost is made with a model")
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("ReaderToolbarHost is created in code")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        model.isAwake ? super.hitTest(point) : nil
    }
}
