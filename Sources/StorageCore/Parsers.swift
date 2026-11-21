import Foundation

/// Parsers for tool output. Each takes the raw text a tool printed and returns plain values,
/// so they can be tested against captured output without running the tools.
public enum Parse {
    /// Docker's human sizes: "8.252GB", "112.8MB", "432kB", "0B", "7.49GB (90%)".
    public static func dockerSize(_ text: String) -> Int64? {
        let s = text.split(separator: " ").first.map(String.init) ?? text
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, factor) in units where s.hasSuffix(suffix) {
            guard let value = Double(s.dropLast(suffix.count)) else { return nil }
            return Int64((value * factor).rounded())
        }
        return nil
    }

    /// A JSON array of objects (`--format json`), with string, number and boolean values
    /// as strings ("true"/"false" for booleans); nil when it isn't one.
    public static func jsonArray(_ text: String) -> [[String: String]]? {
        (try? JSONDecoder().decode([[String: Scalar]].self, from: Data(text.utf8)))?.map { $0.compactMapValues(\.text) }
    }

    /// A JSON value kept as text when it's a string, number or boolean.
    private struct Scalar: Decodable {
        var text: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { text = b ? "true" : "false" }
            else if let i = try? c.decode(Int64.self) { text = String(i) }
            else if let d = try? c.decode(Double.self) { text = String(d) }
            else { text = try? c.decode(String.self) }
        }
    }

    /// One JSON object per line, as printed by `--format '{{json .}}'`. Lines that aren't
    /// valid JSON objects are ignored.
    public static func jsonLines(_ text: String) -> [[String: String]] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object.compactMapValues { value in
                switch value {
                case let s as String: s
                case let n as NSNumber: n.stringValue
                default: nil
                }
            }
        }
    }

    public struct DockerUsage: Equatable, Sendable {
        public var type: String
        public var total: Int
        public var active: Int
        public var size: Int64
        public var reclaimable: Int64
    }

    /// `docker system df --format '{{json .}}'`
    public static func dockerSystemDF(_ text: String) -> [DockerUsage] {
        jsonLines(text).compactMap { row in
            // Podman prints exact byte counts too (RawSize); Docker only rounded text.
            guard let type = row["Type"], let size = row["RawSize"].flatMap({ Int64($0) }) ?? row["Size"].flatMap(dockerSize) else { return nil }
            return DockerUsage(type: type, total: Int(row["TotalCount"] ?? "") ?? 0, active: Int(row["Active"] ?? "") ?? 0,
                               size: size, reclaimable: row["RawReclaimable"].flatMap({ Int64($0) }) ?? row["Reclaimable"].flatMap(dockerSize) ?? 0)
        }
    }

    public struct BuildRecord: Equatable, Sendable {
        public var id: String
        public var bytes: Int64?
        public var reclaimable: Bool
    }

    /// `docker buildx du --verbose`: blank-line-separated records of "Key: value" lines.
    /// Records in use show `Reclaimable: false`.
    public static func buildxRecords(_ text: String) -> [BuildRecord] {
        text.components(separatedBy: "\n\n").compactMap { block in
            var fields: [String: String] = [:]
            for line in block.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                fields[line[..<colon].trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let id = fields["ID"], !id.isEmpty else { return nil }
            return BuildRecord(id: id, bytes: fields["Size"].flatMap(dockerSize), reclaimable: fields["Reclaimable"] == "true")
        }
    }

    /// Non-empty lines that look like absolute paths (tools that print one path per line).
    public static func paths(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/") }
    }

    /// `nix-store -q --size <paths…>` prints one byte count per line.
    public static func nixSizes(_ text: String) -> Int64 {
        text.split(whereSeparator: \.isNewline).compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }.reduce(0, +)
    }

    public struct BrewCleanup: Equatable, Sendable {
        public var targets: [Target]
        public var total: Int64?
        /// Lines that announce anything other than a listed removal (pruned links,
        /// autoremoved formulae). When there are any, the list isn't the whole scope.
        public var unrecognized: [String] = []
    }

    /// `brew cleanup -n`: "Would remove: /path (N files, 33.6MB)" lines and a closing
    /// "This operation would free approximately 240.5MB of disk space."
    public static func brewCleanup(_ text: String) -> BrewCleanup {
        var targets: [Target] = [], unrecognized: [String] = []
        var total: Int64?
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("Would remove: ") {
                // "<path> (<details>)": paths may contain " (", so split at the last one.
                let rest = String(line.dropFirst("Would remove: ".count))
                let open = rest.range(of: " (", options: .backwards)
                let path = open.map { String(rest[..<$0.lowerBound]) } ?? rest
                let details = open.map { rest[$0.upperBound...] } ?? ""
                let size = details.split(separator: ",").last.flatMap { dockerSize($0.trimmingCharacters(in: CharacterSet(charactersIn: " )"))) }
                targets.append(Target(path, bytes: size))
            } else if let r = line.range(of: "free approximately ") {
                total = dockerSize(line[r.upperBound...].components(separatedBy: " ").first ?? "")
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                unrecognized.append(line)
            }
        }
        return BrewCleanup(targets: targets, total: total, unrecognized: unrecognized)
    }
}
