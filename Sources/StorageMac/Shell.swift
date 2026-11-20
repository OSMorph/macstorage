import Darwin
import Foundation

/// The result of running a tool.
public struct ToolOutput: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    /// True when output beyond `Shell.maxOutputBytes` was dropped.
    public var truncated: Bool

    public init(status: Int32, stdout: String, stderr: String = "", timedOut: Bool = false, truncated: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.truncated = truncated
    }

    /// Exited 0 with complete output: safe to parse as the whole answer.
    public var succeeded: Bool { status == 0 && !timedOut && !truncated }
}

public enum ShellError: Error, LocalizedError {
    case toolNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let name): "\(name) isn't installed or couldn't be found."
        }
    }
}

/// Something that runs tools. The executor and providers depend on this, so tests can
/// substitute a fake.
public protocol ToolRunning: Sendable {
    func run(_ tool: String, _ arguments: [String], timeout: Duration) async throws -> ToolOutput
    func isInstalled(_ tool: String) -> Bool
}

extension ToolRunning {
    public func run(_ tool: String, _ arguments: [String]) async throws -> ToolOutput {
        try await run(tool, arguments, timeout: .seconds(60))
    }
}

/// Runs tools by absolute path with an argument list: never through a shell, so no
/// argument can be interpreted as shell syntax.
public struct Shell: ToolRunning {
    public let tools: ToolLocator
    public static let maxOutputBytes = 16_000_000

    public init(tools: ToolLocator) {
        self.tools = tools
    }

    public func isInstalled(_ tool: String) -> Bool { tools.url(for: tool) != nil }

    /// Runs `tool` with `arguments`. After `timeout`, or when the calling task is cancelled,
    /// the process gets SIGTERM, then SIGKILL two seconds later.
    public func run(_ tool: String, _ arguments: [String], timeout: Duration) async throws -> ToolOutput {
        guard let url = tools.url(for: tool) else { throw ShellError.toolNotFound(tool) }
        return try await Self.run(url, arguments, environment: tools.environment, timeout: timeout)
    }

    static func run(_ url: URL, _ arguments: [String], environment: [String: String], timeout: Duration) async throws -> ToolOutput {
        let job = Job(url, arguments, environment)
        try job.start()
        let deadline = ContinuousClock.now + timeout
        var timedOut = false
        await withTaskCancellationHandler {
            while job.process.isRunning {
                if ContinuousClock.now >= deadline { timedOut = true; break }
                try? await Task.sleep(for: .milliseconds(50))
            }
        } onCancel: {
            job.stop()
        }
        if job.process.isRunning { job.stop() }
        // Wait for exit, but never forever: a child holding the pipes open can't block us.
        let waitUntil = ContinuousClock.now + .seconds(5)
        while job.process.isRunning, ContinuousClock.now < waitUntil { try? await Task.sleep(for: .milliseconds(50)) }
        let (out, err, truncated) = job.finish()
        return ToolOutput(status: job.process.isRunning ? -1 : job.process.terminationStatus, stdout: out, stderr: err,
                          timedOut: timedOut, truncated: truncated)
    }

    /// A process and its output, captured incrementally up to a cap. `Process` isn't
    /// Sendable; this box is safe because all mutable state is behind `lock`, and the
    /// process is only started once, then only queried or signalled.
    private final class Job: @unchecked Sendable {
        let process = Process()
        private let out = Pipe(), err = Pipe()
        private let lock = NSLock()
        private var stdout = Data(), stderr = Data(), dropped = false

        init(_ url: URL, _ arguments: [String], _ environment: [String: String]) {
            process.executableURL = url
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out
            process.standardError = err
        }

        func start() throws {
            out.fileHandleForReading.readabilityHandler = { [weak self] h in self?.append(h.availableData, error: false) }
            err.fileHandleForReading.readabilityHandler = { [weak self] h in self?.append(h.availableData, error: true) }
            try process.run()
        }

        private func append(_ data: Data, error: Bool) {
            lock.withLock {
                let room = Shell.maxOutputBytes - stdout.count - stderr.count
                if data.count > room { dropped = true }
                if error { stderr.append(data.prefix(max(0, room))) } else { stdout.append(data.prefix(max(0, room))) }
            }
        }

        func stop() {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }

        func finish() -> (String, String, Bool) {
            for pipe in [out, err] {
                pipe.fileHandleForReading.readabilityHandler = nil
                append(pipe.fileHandleForReading.availableDataIfAny, error: pipe === err)
                try? pipe.fileHandleForReading.close()
            }
            return lock.withLock { (String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self), dropped) }
        }
    }
}

private extension FileHandle {
    /// Whatever is left in the pipe without blocking on a writer that never closes it.
    var availableDataIfAny: Data {
        var flags = fcntl(fileDescriptor, F_GETFL)
        flags |= O_NONBLOCK
        _ = fcntl(fileDescriptor, F_SETFL, flags)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = Darwin.read(fileDescriptor, &buffer, buffer.count)
            guard n > 0 else { break }
            result.append(buffer, count: n)
        }
        return result
    }
}

/// Finds developer tools. GUI apps don't get the login shell's PATH, so this looks in the
/// login shell's PATH (read once), then in well-known install locations.
///
/// Trust note: the login shell's configuration decides which `docker`, `nix-store` and so
/// on the app runs, exactly as it does for the user in Terminal. The app runs nothing a
/// Terminal session wouldn't.
public struct ToolLocator: Sendable {
    public let searchPath: [String]
    public let commandLineToolsInstalled: Bool

    /// /usr/bin stubs that open an installer dialog when the Command Line Tools are missing.
    static let installerStubs: Set<String> = ["git", "python3", "pip3", "xcrun", "xcodebuild", "make", "clang", "swift"]

    static let knownLocations = [
        "/opt/homebrew/bin", "/usr/local/bin", "~/.nix-profile/bin", "/etc/profiles/per-user/$USER/bin",
        "/run/current-system/sw/bin", "/nix/var/nix/profiles/default/bin", "~/.orbstack/bin",
        "/Applications/Docker.app/Contents/Resources/bin", "~/.volta/bin", "~/.bun/bin", "~/.cargo/bin",
        "~/go/bin", "~/.local/bin", "~/Library/pnpm", "/opt/podman/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    public init(searchPath: [String], commandLineToolsInstalled: Bool) {
        self.searchPath = searchPath
        self.commandLineToolsInstalled = commandLineToolsInstalled
    }

    /// Reads the login shell's PATH and checks for the Command Line Tools.
    public static func discover() async -> ToolLocator {
        let home = NSHomeDirectory(), user = NSUserName()
        let expand = { (p: String) in
            (p.hasPrefix("~") ? home + p.dropFirst() : p).replacingOccurrences(of: "/$USER/", with: "/\(user)/")
        }
        var dirs: [String] = []
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let out = try? await Shell.run(URL(fileURLWithPath: shell), ["-ilc", "printf '\\n__PATH__%s\\n' \"$PATH\""],
                                          environment: ProcessInfo.processInfo.environment, timeout: .seconds(15)),
           let line = out.stdout.split(separator: "\n").last(where: { $0.hasPrefix("__PATH__") }) {
            dirs += line.dropFirst("__PATH__".count).split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        }
        dirs += knownLocations.map(expand)
        var seen = Set<String>()
        let unique = dirs.filter { seen.insert($0).inserted }
        let clt = (try? await Shell.run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"], environment: [:], timeout: .seconds(10)))?.status == 0
        return ToolLocator(searchPath: unique, commandLineToolsInstalled: clt)
    }

    public func url(for tool: String) -> URL? {
        for dir in searchPath {
            let path = dir + "/" + tool
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            if dir == "/usr/bin", Self.installerStubs.contains(tool), !commandLineToolsInstalled { return nil }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public var environment: [String: String] {
        [
            "PATH": searchPath.joined(separator: ":"), "HOME": NSHomeDirectory(), "USER": NSUserName(),
            "LANG": "en_US.UTF-8", "TERM": "dumb", "NO_COLOR": "1",
            "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1", "DOCKER_CLI_HINTS": "false",
        ]
    }
}
