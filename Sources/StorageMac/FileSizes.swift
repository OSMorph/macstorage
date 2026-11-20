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

    /// Bytes shared with other files (clones), so not freed by deleting this.
    public var shared: Int64 { max(0, allocated - privateBytes) }
    /// Every file was seen and read.
    public var isComplete: Bool { finished && unreadable == 0 }
    /// The allocated size, marked as a lower bound when the walk was incomplete.
    public var onDisk: Measure { isComplete ? .bytes(allocated) : .atLeast(allocated) }
    /// The private size, marked as a lower bound when the walk was incomplete.
    public var reclaimable: Measure { isComplete ? .bytes(privateBytes) : .atLeast(privateBytes) }
}

/// Options for a walk.
public struct WalkOptions: Sendable {
    /// Absolute paths not to enter (folders macOS protects without Full Disk Access).
    public var excluding: Set<String> = []
    /// Don't enter folders that are git checkouts (they belong to the Git owner).
    public var skipGitCheckouts = false
    public var limit: Duration = .seconds(120)

    public init(excluding: Set<String> = [], skipGitCheckouts: Bool = false, limit: Duration = .seconds(120)) {
        self.excluding = excluding
        self.skipGitCheckouts = skipGitCheckouts
        self.limit = limit
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

    /// `path` with every symlink in its *parent* folders resolved; the last component is
    /// kept as is. Containment checks use this, so `~/link/file` with `link → /etc` is
    /// seen as `/etc/file`.
    public static func resolvingAncestors(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        return (parent as NSString).appendingPathComponent(url.lastPathComponent)
    }

    /// Walks `path` without following symlinks or leaving the volume.
    public static func measure(_ path: String, _ options: WalkOptions = WalkOptions()) -> FolderSize {
        var size = FolderSize()
        walk(path, options, into: &size) { _, _ in }
        return size
    }

    /// Every file under `path` with its size and identity, for a cleanup manifest, plus
    /// whether the list is complete.
    public static func manifest(_ path: String, _ options: WalkOptions = WalkOptions()) -> (targets: [Target], size: FolderSize) {
        var size = FolderSize()
        var targets: [Target] = []
        walk(path, options, into: &size) { p, st in
            targets.append(Target(p, bytes: Int64(st.st_blocks) * 512, identity: FileIdentity(
                device: Int64(st.st_dev), inode: UInt64(st.st_ino), modified: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)))
        }
        return (targets, size)
    }

    /// The entries directly inside `path`, largest first. Entries in `options.excluding`
    /// are left out without being opened.
    public static func children(of path: String, _ options: WalkOptions = WalkOptions()) -> [(name: String, size: FolderSize)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.filter { !options.excluding.contains(path + "/" + $0) }
            .map { ($0, measure(path + "/" + $0, options)) }
            .sorted { $0.size.allocated > $1.size.allocated }
    }

    private static func walk(_ path: String, _ options: WalkOptions, into size: inout FolderSize, file: (String, stat) -> Void) {
        let deadline = ContinuousClock.now + options.limit
        var seenInodes = Set<UInt64>()
        var st = stat()
        guard !options.excluding.contains(path), lstat(path, &st) == 0 else { size.unreadable += 1; return }
        let rootDevice = st.st_dev

        func add(_ p: String, _ st: stat) {
            if st.st_nlink > 1, !seenInodes.insert(UInt64(st.st_ino)).inserted { return }
            let allocated = Int64(st.st_blocks) * 512
            size.files += 1
            size.allocated += allocated
            size.privateBytes += privateBytes(p) ?? allocated
            file(p, st)
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
            if Task.isCancelled || ContinuousClock.now > deadline { size.finished = false; break }
            let p = url.path
            guard lstat(p, &st) == 0 else { unreadable += 1; continue }
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                if st.st_dev != rootDevice || options.excluding.contains(p)
                    || (options.skipGitCheckouts && FileManager.default.fileExists(atPath: p + "/.git")) {
                    walker.skipDescendants()
                }
            case S_IFREG: add(p, st)
            default: break   // symlinks and special files take no meaningful space
            }
        }
        size.unreadable += unreadable
    }
}
