import Foundation
import Darwin

/// Size facts about one file, from several APIs, so M0 can compare them.
struct FileFacts {
    var logical: Int64 = 0          // st_size
    var allocated: Int64 = 0        // st_blocks * 512
    var linkCount: Int = 0
    var inode: UInt64 = 0
    var privateSize: Int64?         // ATTR_CMNEXT_PRIVATESIZE: bytes not shared with clones
    var cloneID: UInt64?            // ATTR_CMNEXT_CLONEID
    var cloneRefCount: UInt32?      // ATTR_CMNEXT_CLONE_REFCNT
    var urlAllocated: Int64?        // URLResourceKey.fileAllocatedSizeKey
    var urlTotalAllocated: Int64?   // URLResourceKey.totalFileAllocatedSizeKey
    var error: String?
}

enum FileSizes {
    // Values from <sys/attr.h>, spelled out so the probe doesn't depend on how the
    // SDK's macros import into Swift.
    private static let ATTR_BIT_MAP_COUNT: UInt16 = 5
    private static let ATTR_CMN_RETURNED_ATTRS: UInt32 = 0x8000_0000
    private static let ATTR_CMNEXT_PRIVATESIZE: UInt32 = 0x0000_0008
    private static let ATTR_CMNEXT_CLONEID: UInt32 = 0x0000_0100
    private static let ATTR_CMNEXT_CLONE_REFCNT: UInt32 = 0x0000_1000
    private static let FSOPT_NOFOLLOW: UInt32 = 0x0000_0001
    private static let FSOPT_ATTR_CMN_EXTENDED: UInt32 = 0x0000_0020

    static func facts(_ path: String) -> FileFacts {
        var f = FileFacts()
        var st = stat()
        if lstat(path, &st) != 0 {
            f.error = String(cString: strerror(errno))
            return f
        }
        f.logical = Int64(st.st_size)
        f.allocated = Int64(st.st_blocks) * 512
        f.linkCount = Int(st.st_nlink)
        f.inode = UInt64(st.st_ino)

        let ext = extendedAttributes(path)
        f.privateSize = ext.privateSize
        f.cloneID = ext.cloneID
        f.cloneRefCount = ext.cloneRefCount
        if f.error == nil, let e = ext.error { f.error = "getattrlist: \(e)" }

        let url = URL(fileURLWithPath: path)
        if let v = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey]) {
            f.urlAllocated = v.fileAllocatedSize.map { Int64($0) }
            f.urlTotalAllocated = v.totalFileAllocatedSize.map { Int64($0) }
        }
        return f
    }

    static func extendedAttributes(_ path: String) -> (privateSize: Int64?, cloneID: UInt64?, cloneRefCount: UInt32?, error: String?) {
        var list = attrlist()
        list.bitmapcount = ATTR_BIT_MAP_COUNT
        list.commonattr = ATTR_CMN_RETURNED_ATTRS
        list.forkattr = ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT

        var buffer = [UInt8](repeating: 0, count: 256)
        let rc = buffer.withUnsafeMutableBytes { raw -> Int32 in
            getattrlist(path, &list, raw.baseAddress!, raw.count, FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)
        }
        if rc != 0 { return (nil, nil, nil, String(cString: strerror(errno))) }

        return buffer.withUnsafeBytes { raw in
            // Layout: u_int32 length, attribute_set_t returned (5 x u_int32), then the
            // returned common-extended attributes in bit order.
            let returnedFork = raw.loadUnaligned(fromByteOffset: 4 + 16, as: UInt32.self)
            var offset = 4 + 20
            var privateSize: Int64?
            var cloneID: UInt64?
            var refCount: UInt32?
            if returnedFork & ATTR_CMNEXT_PRIVATESIZE != 0 {
                privateSize = raw.loadUnaligned(fromByteOffset: offset, as: Int64.self); offset += 8
            }
            if returnedFork & ATTR_CMNEXT_CLONEID != 0 {
                cloneID = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self); offset += 8
            }
            if returnedFork & ATTR_CMNEXT_CLONE_REFCNT != 0 {
                refCount = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
            return (privateSize, cloneID, refCount, nil)
        }
    }

    struct DirTotals {
        var path: String
        var exists = true
        var files = 0
        var allocated: Int64 = 0        // hard links counted once
        var privateSize: Int64 = 0      // clone-aware
        var privateSizeKnown = true
        var largestFiles: [(path: String, logical: Int64, allocated: Int64)] = []
        var complete = true             // false when the time limit stopped the walk
        var unreadable = 0
        var seconds: TimeInterval = 0
    }

    /// Walks a folder and adds up allocated and clone-aware sizes. Doesn't follow symlinks.
    static func directoryTotals(_ path: String, timeLimit: TimeInterval, trackLargerThan: Int64 = 512 << 20,
                                skipping skip: Set<String> = []) -> DirTotals {
        var totals = DirTotals(path: path)
        let start = Date()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            totals.exists = false
            return totals
        }
        if !isDir.boolValue {
            let f = facts(path)
            totals.files = 1
            totals.allocated = f.allocated
            if let p = f.privateSize { totals.privateSize = p } else { totals.privateSizeKnown = false }
            if f.logical >= trackLargerThan { totals.largestFiles = [(path, f.logical, f.allocated)] }
            return totals
        }

        var seenInodes = Set<UInt64>()
        let url = URL(fileURLWithPath: path)
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                        options: [], errorHandler: { _, _ in
            totals.unreadable += 1
            return true
        })
        while let item = enumerator?.nextObject() as? URL {
            if Date().timeIntervalSince(start) > timeLimit { totals.complete = false; break }
            if !skip.isEmpty, skip.contains(item.lastPathComponent) { enumerator?.skipDescendants(); continue }
            var st = stat()
            if lstat(item.path, &st) != 0 { totals.unreadable += 1; continue }
            let mode = st.st_mode & S_IFMT
            if mode == S_IFDIR || mode == S_IFLNK { continue }
            if st.st_nlink > 1 {
                if seenInodes.contains(UInt64(st.st_ino)) { continue }
                seenInodes.insert(UInt64(st.st_ino))
            }
            totals.files += 1
            let allocated = Int64(st.st_blocks) * 512
            totals.allocated += allocated
            if let p = extendedAttributes(item.path).privateSize { totals.privateSize += p } else { totals.privateSizeKnown = false }
            if Int64(st.st_size) >= trackLargerThan {
                totals.largestFiles.append((item.path, Int64(st.st_size), allocated))
            }
        }
        totals.largestFiles.sort { $0.allocated > $1.allocated }
        totals.largestFiles = Array(totals.largestFiles.prefix(10))
        totals.seconds = Date().timeIntervalSince(start)
        return totals
    }

    static func format(_ bytes: Int64?) -> String {
        guard let bytes else { return "n/a" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
