// GUI entry (T5, design §1.1 — single binary, double mode).
//
// `main.swift` dispatches no-argv launches here. The app is a menu-bar agent
// (`.accessory` activation policy; the LSUIElement .app bundle arrives with T6 packaging).
// It is NOT marked `@main` — main.swift already owns the executable entry point — so the
// GUI branch calls `EnvCueGUIApp.main()` explicitly.
//
// Screenshot harness (segment 1 only): with ENVCUE_GUI_PREVIEW=1 the app switches to
// `.regular` and opens a plain window that lays out the same glass views against the
// desktop, so the Liquid Glass material can be captured for the visual gate. The shipping
// shell is the MenuBarExtra alone.

import SwiftUI
import AppKit
import EnvCueCore

/// Launch the SwiftUI app. Never returns (runs the AppKit run loop). The shipping shell is
/// `EnvCueGUIApp` (MenuBarExtra); ENVCUE_GUI_PREVIEW selects the segment-1 capture harness.
@MainActor
func runGUI() -> Never {
    if ProcessInfo.processInfo.environment["ENVCUE_GUI_PREVIEW"] != nil {
        PreviewApp.main()
    } else {
        EnvCueGUIApp.main()
    }
    // App.main() does not return; satisfy `Never`.
    fatalError("unreachable: SwiftUI App.main() does not return")
}

/// The shipping menu-bar agent (`.accessory`, no Dock icon). Backed by the live apply path.
struct EnvCueGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel = {
        let source = LiveSceneSource()
        return AppModel(source: source, watching: source.configFile)
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            // Label = SF Symbol (scene state) + scene name (FR-1). Tahoe's menu bar is
            // itself transparent Liquid Glass, so we draw no background here.
            Image(systemName: "square.stack.3d.up.fill")
            Text(model.labelText)
        }
        .menuBarExtraStyle(.window) // rich content window (carries the scene list / diff)
    }
}

/// Makes the harness window non-opaque with a clear background, so the Liquid Glass views
/// refract the real desktop (as the shipping menu-bar window does). Segment-1 harness only.
private struct ClearWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovableByWindowBackground = true
        }
    }
}

/// Segment-1 screenshot harness: a plain window hosting the same glass views, so the
/// Liquid Glass material can be captured against the desktop for the visual gate. Selected
/// by ENVCUE_GUI_PREVIEW; not part of the shipping UI.
struct PreviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("EnvCue — Liquid Glass preview", id: "preview") {
            PreviewGalleryView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 560)
    }
}

/// Presents the standard About panel reliably from a menu-bar agent. Two fixes over a bare
/// `orderFrontStandardAboutPanel(nil)`:
///   1. Pass the bundle icon EXPLICITLY via `.applicationIcon` — the panel otherwise renders
///      a low-res placeholder (it does not honor `applicationIconImage`, and a process
///      launched outside LaunchServices has no registered icon). A 1024px source scaled down
///      is crisp.
///   2. Raise the panel above the menu-bar popup (which floats at `.popUpMenu` level and would
///      otherwise occlude it); making it key also dismisses the popup. A weak ref handles the
///      panel's reuse on subsequent opens.
@MainActor
final class AboutPresenter {
    static let shared = AboutPresenter()
    private weak var panel: NSWindow?

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let panel {            // reuse the already-created panel
            raise(panel)
            return
        }
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let icon = Self.bundleIcon() { options[.applicationIcon] = icon }
        let before = Set(NSApp.windows)
        NSApp.orderFrontStandardAboutPanel(options: options)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let new = NSApp.windows.first(where: { $0.isVisible && !before.contains($0) }) {
                self.panel = new
                self.raise(new)
            }
        }
    }

    private func raise(_ w: NSWindow) {
        w.level = .popUpMenu          // match the menu popup's level…
        w.makeKeyAndOrderFront(nil)   // …and become key so the popup dismisses
        w.orderFrontRegardless()
    }

    /// Bundle icon as a high-res image: prefer the 1024 PNG (clean downscale), fall back to
    /// the multi-rep icns. Nil only if neither resource resolves (e.g. a non-bundle launch).
    private static func bundleIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "envcue-icon-1024", withExtension: "png"),
           let img = NSImage(contentsOf: url) { return img }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) { return img }
        return nil
    }
}

/// Sets the activation policy: menu-bar accessory normally, regular (visible window) when
/// the preview harness is on so a window appears and can be screen-captured.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let preview = ProcessInfo.processInfo.environment["ENVCUE_GUI_PREVIEW"] != nil
        NSApp.setActivationPolicy(preview ? .regular : .accessory)
        if preview { NSApp.activate(ignoringOtherApps: true) }

        // Load the high-res bundle icon explicitly. When the binary is launched directly
        // (e.g. from a terminal) rather than via LaunchServices, applicationIconImage is left
        // as a low-res placeholder, so the standard About panel renders a blurry icon. Setting
        // it from the .icns guarantees a crisp About/Dock icon regardless of launch path.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }
}

/// Screenshot layout for the visual gate: the menu in its two states — scene list and the
/// inline diff preview — side by side over the real desktop. Demo data only; not shipped.
private struct PreviewGalleryView: View {
    // Two independent demo-backed models: one resting on the list, one with a pending switch.
    @State private var listModel = AppModel(source: DemoSceneSource())
    @State private var diffModel: AppModel = {
        let m = AppModel(source: DemoSceneSource())
        m.beginSwitch(to: SceneOption(name: "work")) // open the inline diff for the capture
        return m
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            labeled("Scene list") { MenuView(model: listModel) }
            labeled("Inline diff preview") { MenuView(model: diffModel) }
        }
        .padding(36)
        // Transparent window so the glass refracts the real desktop, mirroring the shipping
        // MenuBarExtra window. Without this the glass sits on an opaque backing and looks flat.
        .background(ClearWindowBackground())
    }

    private func labeled<Content: View>(_ caption: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}
