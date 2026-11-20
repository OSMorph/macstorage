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
    /// False when the time limit stopped the walk early.
    public var complete = true

    /// Bytes shared with other files (clones), so not freed by deleting this.
    public var shared: Int64 { max(0, allocated - privateBytes) }
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

    /// Walks `path` without following symlinks or leaving the volume. Stops early when the
    /// calling task is cancelled or `limit` passes, and says so in `complete`.
    public static func measure(_ path: String, limit: Duration = .seconds(120)) -> FolderSize {
        var size = FolderSize()
        let deadline = ContinuousClock.now + limit
        var seenInodes = Set<UInt64>()
        var st = stat()
        guard lstat(path, &st) == 0 else { size.unreadable = 1; return size }
        let rootDevice = st.st_dev

        func add(_ p: String, _ st: stat) {
            if st.st_nlink > 1, !seenInodes.insert(UInt64(st.st_ino)).inserted { return }
            let allocated = Int64(st.st_blocks) * 512
            size.files += 1
            size.allocated += allocated
            size.privateBytes += privateBytes(p) ?? allocated
        }

        if st.st_mode & S_IFMT != S_IFDIR { add(path, st); return size }
        guard let walker = FileManager.default.enumerator(atPath: path) else { size.unreadable = 1; return size }
        while let relative = walker.nextObject() as? String {
            if Task.isCancelled || ContinuousClock.now > deadline { size.complete = false; break }
            let p = path + "/" + relative
            guard lstat(p, &st) == 0 else { size.unreadable += 1; continue }
            switch st.st_mode & S_IFMT {
            case S_IFDIR: if st.st_dev != rootDevice { walker.skipDescendants() }
            case S_IFREG: add(p, st)
            default: break   // symlinks and special files take no meaningful space
            }
        }
        return size
    }

    /// The entries directly inside `path`, with their sizes, largest first.
    public static func children(of path: String, limit: Duration = .seconds(60)) -> [(name: String, size: FolderSize)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.map { ($0, measure(path + "/" + $0, limit: limit)) }.sorted { $0.size.allocated > $1.size.allocated }
    }

    /// Every file under `path` with its allocated size, for a cleanup manifest.
    public static func manifest(_ path: String, max: Int = 1_000_000) -> [Target] {
        guard let walker = FileManager.default.enumerator(atPath: path) else { return [] }
        var targets: [Target] = []
        var st = stat()
        while let relative = walker.nextObject() as? String, targets.count < max {
            let p = path + "/" + relative
            guard lstat(p, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }
            targets.append(Target(p, bytes: Int64(st.st_blocks) * 512))
        }
        return targets
    }
}
