import AppKit
import StorageCore
import SwiftUI

/// Launch options:
/// - `--demo`: show sample data and simulate cleanups (nothing is touched).
/// - `--snapshots <folder>`: walk every screen, save each as a PNG, then quit (used by CI).
/// - `--appearance light|dark`: force an appearance.
struct LaunchOptions {
    var demo = false
    var snapshots: URL?
    var appearance: NSAppearance.Name?

    static let current = LaunchOptions(CommandLine.arguments)

    init(_ args: [String]) {
        demo = args.contains("--demo")
        if let i = args.firstIndex(of: "--snapshots"), args.indices.contains(i + 1) { snapshots = URL(fileURLWithPath: args[i + 1]) }
        if let i = args.firstIndex(of: "--appearance"), args.indices.contains(i + 1) {
            appearance = args[i + 1] == "dark" ? .darkAqua : .aqua
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let model = AppModel(demo: LaunchOptions.current.demo)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions.current
        if let name = options.appearance { NSApp.appearance = NSAppearance(named: name) }
        guard let folder = options.snapshots else { return }
        Task { await SnapshotTour(model: Self.model, folder: folder).run() }
    }
}

@main
struct MacStorageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppDelegate.model

    var body: some Scene {
        Window("macstorage", id: "main") {
            RootView(model: model).frame(minWidth: 1040, minHeight: 700)
        }
        .defaultSize(width: 1280, height: 860)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan Again") { model.scan() }.keyboardShortcut("r").disabled(model.scanning != nil || model.demo)
            }
        }
    }
}

/// Walks every screen and state and saves a PNG of each, for automated QA.
@MainActor
struct SnapshotTour {
    let model: AppModel
    let folder: URL

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("snapshot tour: \(message)\n".utf8))
    }

    func run() async {
        Self.log("started, writing to \(folder.path)")
        let watchdog = Task { try? await Task.sleep(for: .seconds(240)); guard !Task.isCancelled else { return }; Self.log("timed out"); exit(2) }
        defer { watchdog.cancel() }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let window = await mainWindow()
        Self.log("capturing a \(Int(window.frame.width))×\(Int(window.frame.height)) window")

        for section in AppSection.allCases {
            model.section = section
            await shot(section.rawValue, window)
        }
        model.show(owner: "docker", item: "docker/dockerBuildCache")
        await shot("owners-docker", window)
        model.show(owner: "docker", item: "docker/dockerUnusedVolumes")
        await shot("owners-docker-volumes", window)
        model.show(owner: "downloads", item: "downloads/downloads")
        model.picks["downloads/downloads"] = ["~/Downloads/Xcode_26.1.xip", "~/Downloads/Docker.dmg"]
        await shot("owners-downloads-picked", window)
        model.section = .cleanup
        model.selected.insert("docker/dockerUnusedImages")
        await shot("cleanup-with-picks", window)
        model.openPreview()
        await shot("sheet-preview", window, sheet: true)
        if case .preview(let plan)? = model.sheet {
            model.run(plan)
            await shot("sheet-running", window, sheet: true, wait: 0.5)
            while case .running? = model.sheet { try? await Task.sleep(for: .milliseconds(200)) }
            await shot("sheet-results", window, sheet: true)
        }
        model.sheet = nil
        model.section = .history
        await shot("history-after-cleanup", window)
        model.show(owner: "go", item: "go/goModuleCache")
        await shot("owners-cleaned-item", window)
        let saved = model.snapshot
        model.setSnapshot(nil)
        await shot("welcome", window)
        model.setSnapshot(saved)
        Self.log("done")
        NSApp.terminate(nil)
    }

    /// The app's window, or one made for the tour if none appeared (headless CI sessions).
    private func mainWindow() async -> NSWindow {
        for _ in 0..<20 {
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil && $0.contentView != nil }) { return w }
            try? await Task.sleep(for: .milliseconds(250))
        }
        Self.log("no window appeared; creating one")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: RootView(model: model).frame(width: 1280, height: 860))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func shot(_ name: String, _ window: NSWindow, sheet: Bool = false, wait: Double = 0.6) async {
        try? await Task.sleep(for: .seconds(wait))
        guard let view = (sheet ? window.attachedSheet ?? window : window).contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Self.log("\(name): nothing to capture")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name)-\(appearance).png"))
            Self.log("\(name) saved")
        } catch {
            Self.log("\(name): \(error.localizedDescription)")
        }
    }
}
