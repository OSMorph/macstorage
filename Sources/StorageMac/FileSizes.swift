import Darwin
import Foundation
import StorageCore

/// Size of a folder (or file) as APFS stores it.
public struct FolderSize: Sendable, Equatable {
    /// Allocated bytes, hard links counted once. Blocks shared between clones count in full.
    public var allocated: Int64 = 0
    /// Bytes not shared with any clone: what deleting this would actually free.
    public var privateBytes: Int64 = 0
    public var files = 0
    public var unreadable = 0
    /// False when the time limit or cancellation stopped the walk early.
    public var finished = true
    /// Folders not entered: on another volume, excluded, or a nested git checkout.
    public var skippedSubtrees = 0

    /// Bytes shared with other files (clones), so not freed by deleting this.
    public var shared: Int64 { max(0, allocated - privateBytes) }
    /// Every file was seen and read.
    public var isComplete: Bool { finished && unreadable == 0 }
    /// The allocated size, marked as a lower bound when the walk was incomplete.
    public var onDisk: Measure { isComplete ? .bytes(allocated) : .atLeast(allocated) }
    /// The private size, marked as a lower bound when the walk was incomplete.
    public var reclaimable: Measure { isComplete ? .bytes(privateBytes) : .atLeast(privateBytes) }

    /// Several sizes added up; incomplete if any part is.
    public static func total(_ parts: [FolderSize]) -> FolderSize {
        parts.reduce(into: FolderSize()) { t, p in
            t.allocated += p.allocated
            t.privateBytes += p.privateBytes
            t.files += p.files
            t.unreadable += p.unreadable
            t.finished = t.finished && p.finished
        }
    }
}

/// Options for a walk.
public struct WalkOptions: Sendable {
    /// Absolute paths not to enter (folders macOS protects without Full Disk Access).
    public var excluding: Set<String> = []
    /// Don't enter folders that are git checkouts (they belong to the Git owner).
    public var skipGitCheckouts = false
    public var limit: Duration = .seconds(120)
    /// Stops the walk early (walks run on dispatch queues, where task cancellation can't reach).
    public var stop: StopSignal?

    public init(excluding: Set<String> = [], skipGitCheckouts: Bool = false, limit: Duration = .seconds(120), stop: StopSignal? = nil) {
        self.excluding = excluding
        self.skipGitCheckouts = skipGitCheckouts
        self.limit = limit
        self.stop = stop
    }
}

public enum FileSizes {
    // Values from <sys/attr.h>, spelled out so they don't depend on how macros import.
    private static let returnedAttrs: UInt32 = 0x8000_0000      // ATTR_CMN_RETURNED_ATTRS
    private static let privateSize: UInt32 = 0x0000_0008       // ATTR_CMNEXT_PRIVATESIZE
    private static let noFollow: UInt32 = 0x0000_0001          // FSOPT_NOFOLLOW
    private static let commonExtended: UInt32 = 0x0000_0020    // FSOPT_ATTR_CMN_EXTENDED

    /// Bytes of this file not shared with any APFS clone, or nil if the volume can't say.
    public static func privateBytes(_ path: String) -> Int64? {
        var list = attrlist()
        list.bitmapcount = 5
        list.commonattr = returnedAttrs
        list.forkattr = privateSize
        var buffer = [UInt8](repeating: 0, count: 64)
        let rc = buffer.withUnsafeMutableBytes { getattrlist(path, &list, $0.baseAddress!, $0.count, commonExtended | noFollow) }
        guard rc == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            // u_int32 length, attribute_set_t (5 × u_int32), then the private size.
            let returnedFork = raw.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
            return returnedFork & privateSize != 0 ? raw.loadUnaligned(fromByteOffset: 24, as: Int64.self) : nil
        }
    }

    /// The identity of the object at `path` itself (symlinks are not followed).
    public static func identity(_ path: String) -> FileIdentity? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileIdentity(device: Int64(st.st_dev), inode: UInt64(st.st_ino),
                            modified: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
    }

    /// The identity of the directory `path` resolves to, or nil if it isn't a directory.
    /// Directories are compared by `isSameObject`: their modification time changes
    /// whenever an entry is added.
    public static func directoryIdentity(_ path: String) -> FileIdentity? {
        guard let real = realPath(path), isDirectory(real) else { return nil }
        return identity(real)
    }

    /// True for a real directory (a symlink to one is not).
    public static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    /// `path` with every symlink in its *parent* folders resolved; the last component is
    /// kept as is. Containment checks use this, so `~/link/file` with `link → /etc` is
    /// seen as `/etc/file`.
    public static func resolvingAncestors(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = url.deletingLastPathComponent().path
        return ((realPath(parent) ?? parent) as NSString).appendingPathComponent(url.lastPathComponent)
    }

    /// The path with every symlink resolved, as the filesystem spells it (`/private/var/…`).
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Walks `path` without following symlinks or leaving the volume.
    public static func measure(_ path: String, _ options: WalkOptions = WalkOptions()) -> FolderSize {
        var size = FolderSize()
        walk(path, options, into: &size) { _, _ in }
        return size
    }

    /// Lists beyond this many entries aren't kept: the step is then handed to the user.
    public static let manifestLimit = 200_000

    /// Every entry under `path` (files, folders, symlinks, every name of a hard-linked
    /// file) with its identity, for a cleanup manifest, plus whether the list is complete.
    /// A subtree the walk didn't enter (another volume, an excluded folder) makes it
    /// incomplete. Folders are recorded without a modification time: adding an entry
    /// changes it, and the new entry is listed itself.
    public static func manifest(_ path: String, _ options: WalkOptions = WalkOptions()) -> (targets: [Target], size: FolderSize) {
        var size = FolderSize()
        var targets: [Target] = []
        var truncated = false
        walk(path, options, into: &size) { p, st in
            guard targets.count < manifestLimit else { truncated = true; return }
            let isDirectory = st.st_mode & S_IFMT == S_IFDIR
            let isFile = st.st_mode & S_IFMT == S_IFREG
            targets.append(Target(p, bytes: isFile ? Int64(st.st_blocks) * 512 : nil, identity: FileIdentity(
                device: Int64(st.st_dev), inode: UInt64(st.st_ino),
                modified: isDirectory ? 0 : Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)))
        }
        if truncated || size.skippedSubtrees > 0 { size.finished = false }
        return (targets, size)
    }

    /// A manifest entry's identity as it is now, recorded the way `manifest` records it.
    static func manifestIdentity(_ path: String) -> FileIdentity? {
        guard var identity = identity(path) else { return nil }
        if isDirectory(path) { identity.modified = 0 }
        return identity
    }

    /// The entries directly inside `path`, largest first, or nil if the folder exists but
    /// can't be listed. Entries in `options.excluding` are left out without being opened.
    public static func children(of path: String, _ options: WalkOptions = WalkOptions()) -> [(name: String, size: FolderSize)]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return FileManager.default.fileExists(atPath: path) ? nil : []
        }
        return names.filter { !options.excluding.contains(path + "/" + $0) }
            .map { ($0, measure(path + "/" + $0, options)) }
            .sorted { $0.size.allocated > $1.size.allocated }
    }

    /// Visits every entry below `path` (not `path` itself), adding regular files to `size`
    /// with hard links counted once.
    private static func walk(_ path: String, _ options: WalkOptions, into size: inout FolderSize, entry: (String, stat) -> Void) {
        let deadline = ContinuousClock.now + options.limit
        // Match exclusions however the path is spelled (/var/… is /private/var/… on disk).
        let excluded = Set(options.excluding.flatMap { [$0, realPath($0)].compactMap { $0 } })
        var seenInodes = Set<UInt64>()
        var st = stat()
        guard !excluded.contains(path), lstat(path, &st) == 0 else { size.unreadable += 1; return }
        let rootDevice = st.st_dev

        func add(_ p: String, _ st: stat) {
            if st.st_nlink > 1, !seenInodes.insert(UInt64(st.st_ino)).inserted { return }
            let allocated = Int64(st.st_blocks) * 512
            size.files += 1
            size.allocated += allocated
            size.privateBytes += privateBytes(p) ?? allocated
        }

        guard st.st_mode & S_IFMT == S_IFDIR else {
            if st.st_mode & S_IFMT == S_IFREG { add(path, st) }
            return
        }
        var unreadable = 0
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil, options: [],
                                                          errorHandler: { _, _ in unreadable += 1; return true }) else {
            size.unreadable += 1
            return
        }
        while let url = walker.nextObject() as? URL {
            if Task.isCancelled || options.stop?.isStopped == true || ContinuousClock.now > deadline { size.finished = false; break }
            let p = url.path
            guard lstat(p, &st) == 0 else { unreadable += 1; continue }
            entry(p, st)
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                if st.st_dev != rootDevice || excluded.contains(p)
                    || (options.skipGitCheckouts && FileManager.default.fileExists(atPath: p + "/.git")) {
                    walker.skipDescendants()
                    size.skippedSubtrees += 1
                }
            case S_IFREG: add(p, st)
            default: break   // symlinks and special files take no meaningful space
            }
        }
        size.unreadable += unreadable
    }
}
