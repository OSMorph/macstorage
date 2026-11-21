import Foundation
import Observation
import StorageCore

/// One By folder level measured when it was opened.
public struct FolderLevel: Sendable {
    /// Tells this level from one measured again later at the same path.
    public let id = UUID()
    /// Largest first, like the scan's levels.
    public var entries: [FolderEntry] = []
    /// Entries listed but not measured yet.
    public var pending: Set<String> = []
    /// How many entries the folder has.
    public var total = 0
    /// True while the folder itself is being listed.
    public var listing = false
    /// Why the folder wasn't listed.
    public var problem: FolderAttribution.Refusal?

    public init(entries: [FolderEntry] = [], listing: Bool = false, problem: FolderAttribution.Refusal? = nil) {
        self.entries = entries
        self.listing = listing
        self.problem = problem
    }

    public var isMeasuring: Bool { listing || !pending.isEmpty }
    public var measured: Int { total - pending.count }
}

/// The By folder levels below what the scan measured, measured when opened, one at a
/// time. Leaving a level being measured pauses it: what's measured is kept and the rest
/// is measured on returning (the entry in progress starts over). Results reach the level
/// they were measured for once, in batches, at most every `flushInterval`.
@MainActor @Observable
public final class FolderMeasurements {
    /// Levels by path ("~/Downloads").
    public private(set) var levels: [String: FolderLevel] = [:]
    /// The level being measured now, if any.
    public private(set) var measuring: String?

    @ObservationIgnored private var stop = StopSignal()
    @ObservationIgnored private let home: String
    @ObservationIgnored private let list: @Sendable (String) -> [String]?
    @ObservationIgnored private let measure: @Sendable (_ name: String, _ folder: String, _ owners: [Owner], _ options: WalkOptions) -> FolderEntry?
    @ObservationIgnored private let flushInterval: Duration

    /// `list` and `measure` are the filesystem by default; tests pass their own.
    public init(home: String = NSHomeDirectory(),
                list: @escaping @Sendable (String) -> [String]? = FolderAttribution.names(in:),
                measure: @escaping @Sendable (String, String, [Owner], WalkOptions) -> FolderEntry? = { FolderAttribution.entry($0, in: $1, owners: $2, $3) },
                flushInterval: Duration = .milliseconds(250)) {
        self.home = home
        self.list = list
        self.measure = measure
        self.flushInterval = flushInterval
    }

    /// Opens the level at `path`: checks it may be read, then lists and measures it, or
    /// resumes it, or keeps a finished one. Pauses any other level being measured.
    /// `protected` holds the folders the app mustn't read now.
    public func open(_ path: String, owners: [Owner], protected: Set<String>) {
        if measuring != path { pause() }
        guard measuring != path else { return }
        let full = absolute(path)
        // Checked before any read, every time: a real folder on this volume reached
        // without links, not one macOS protects.
        if let refusal = FolderAttribution.refusal(full, home: home, protected: protected) {
            levels[path] = FolderLevel(problem: refusal)
            return
        }
        if let level = levels[path], level.problem == nil {
            if !level.pending.isEmpty { measure(path, level.pending.sorted(), owners: owners, protected: protected, stop: begin(path)) }
            return
        }
        levels[path] = FolderLevel(listing: true)
        let stop = begin(path), list = list
        Task {
            guard let listed = await offload({ list(full) }) else {
                if !stop.isStopped { levels[path] = FolderLevel(problem: .unreadable); measuring = nil }
                return
            }
            guard !stop.isStopped else { return }
            let names = listed.sorted()
            levels[path]?.listing = false
            levels[path]?.pending = Set(names)
            levels[path]?.total = names.count
            measure(path, names, owners: owners, protected: protected, stop: stop)
        }
    }

    /// Stops measuring. A level still being listed is dropped; one being measured keeps
    /// what it has.
    public func pause() {
        guard let path = measuring else { return }
        stop.stop()
        measuring = nil
        if levels[path]?.listing == true { levels[path] = nil }
    }

    /// Drops every level: they were measured for another scan or another access.
    public func forget() {
        stop.stop()
        measuring = nil
        levels = [:]
    }

    private func begin(_ path: String) -> StopSignal {
        stop = StopSignal()
        measuring = path
        return stop
    }

    private func absolute(_ path: String) -> String { home + path.dropFirst() }

    /// Measures `names` in the level at `path`. A second task shows what's been measured
    /// every `flushInterval`, so a slow entry doesn't hold back those before it.
    private func measure(_ path: String, _ names: [String], owners: [Owner], protected: Set<String>, stop: StopSignal) {
        guard let id = levels[path]?.id else { return }
        let full = absolute(path), measure = measure, interval = flushInterval, home = home
        let options = WalkOptions(excluding: protected, limit: .seconds(30), stop: stop)
        let batch = Batch()
        Task {
            while !batch.finished {
                try? await Task.sleep(for: interval)
                record(batch.take(), in: path, id)
            }
        }
        Task {
            var refused: FolderAttribution.Refusal?
            for name in names {
                // The folder is checked again before each entry: replaced by a link or a
                // protected folder mid-level, measuring stops there.
                let (refusal, entry) = await offload { () -> (FolderAttribution.Refusal?, FolderEntry?) in
                    if let refusal = FolderAttribution.refusal(full, home: home, protected: protected) { return (refusal, nil) }
                    return (nil, measure(name, full, owners, options))
                }
                if let refusal { refused = refusal; break }
                // A stopped walk is incomplete: leave that entry pending.
                guard !stop.isStopped else { break }
                batch.add(name, entry)
            }
            batch.finished = true
            record(batch.take(), in: path, id)
            if let refused, !stop.isStopped, levels[path]?.id == id { levels[path] = FolderLevel(problem: refused) }
            if !stop.isStopped { measuring = nil }
        }
    }

    /// Adds results to the level they were measured for, once: a paused run's last
    /// results can arrive after a resumed run measured the same names.
    private func record(_ results: (found: [FolderEntry], done: [String]), in path: String, _ id: UUID) {
        guard !results.done.isEmpty, levels[path]?.id == id, let pending = levels[path]?.pending else { return }
        let new = results.found.filter { pending.contains($0.name) }.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
        if let entries = levels[path]?.entries { levels[path]?.entries = Self.merge(entries, new) }
        levels[path]?.pending.subtract(results.done)
    }

    /// Two lists sorted largest first, merged into one, without sorting it all again.
    nonisolated static func merge(_ a: [FolderEntry], _ b: [FolderEntry]) -> [FolderEntry] {
        var out: [FolderEntry] = [], i = 0, j = 0
        out.reserveCapacity(a.count + b.count)
        while i < a.count, j < b.count {
            if (a[i].bytes ?? -1) >= (b[j].bytes ?? -1) { out.append(a[i]); i += 1 } else { out.append(b[j]); j += 1 }
        }
        return out + a[i...] + b[j...]
    }

    /// Results measured but not shown yet.
    @MainActor private final class Batch {
        var found: [FolderEntry] = []
        var done: [String] = []
        var finished = false

        func add(_ name: String, _ entry: FolderEntry?) {
            done.append(name)
            if let entry { found.append(entry) }
        }

        func take() -> (found: [FolderEntry], done: [String]) {
            defer { found = []; done = [] }
            return (found, done)
        }
    }
}
