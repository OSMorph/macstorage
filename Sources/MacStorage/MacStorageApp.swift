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

    init(_ args: [String] = CommandLine.arguments) {
        demo = args.contains("--demo")
        if let i = args.firstIndex(of: "--snapshots"), args.indices.contains(i + 1) { snapshots = URL(fileURLWithPath: args[i + 1]) }
        if let i = args.firstIndex(of: "--appearance"), args.indices.contains(i + 1) {
            appearance = args[i + 1] == "dark" ? .darkAqua : .aqua
        }
    }
}

@main
struct MacStorageApp: App {
    @State private var model: AppModel
    private let options = LaunchOptions()

    init() {
        _model = State(initialValue: AppModel(demo: LaunchOptions().demo))
    }

    var body: some Scene {
        Window("macstorage", id: "main") {
            RootView(model: model)
                .frame(minWidth: 1040, minHeight: 700)
                .task {
                    if let name = options.appearance { NSApp.appearance = NSAppearance(named: name) }
                    if let folder = options.snapshots { await SnapshotTour(model: model, folder: folder).run() }
                }
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

    func run() async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await settle()
        for section in AppSection.allCases {
            model.section = section
            await shot(section.rawValue)
        }
        model.show(owner: "docker", item: "dockerBuildCache")
        await shot("owners-docker")
        model.show(owner: "docker", item: "dockerUnusedVolumes")
        await shot("owners-docker-volumes")
        model.show(owner: "downloads", item: "downloads")
        model.picks["downloads"] = ["~/Downloads/Xcode_26.1.xip", "~/Downloads/Docker.dmg"]
        await shot("owners-downloads-picked")
        model.section = .cleanup
        model.selected.insert("dockerUnusedImages")
        await shot("cleanup-with-picks")
        model.openPreview()
        await shot("sheet-preview", sheet: true)
        if case .preview(let plan)? = model.sheet {
            model.run(plan)
            await shot("sheet-running", sheet: true, wait: 0.5)
            while case .running? = model.sheet { try? await Task.sleep(for: .milliseconds(200)) }
            await shot("sheet-results", sheet: true)
        }
        model.sheet = nil
        model.section = .history
        await shot("history-after-cleanup")
        model.show(owner: "go", item: "goModuleCache")
        await shot("owners-cleaned-item")
        let saved = model.snapshot
        model.snapshot = nil
        await shot("welcome")
        model.snapshot = saved
        NSApp.terminate(nil)
    }

    private func settle(_ seconds: Double = 0.6) async { try? await Task.sleep(for: .seconds(seconds)) }

    private func shot(_ name: String, sheet: Bool = false, wait: Double = 0.6) async {
        await settle(wait)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }),
              let target = (sheet ? window.attachedSheet ?? window : window).contentView else { return }
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
        target.cacheDisplay(in: target.bounds, to: rep)
        let appearance = NSApp.appearance?.name == .darkAqua ? "dark" : "light"
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name)-\(appearance).png"))
    }
}
