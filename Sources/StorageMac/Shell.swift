import Foundation

/// The result of running a tool.
public struct ToolOutput: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public var succeeded: Bool { status == 0 && !timedOut }
}

public enum ShellError: Error, LocalizedError {
    case toolNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let name): "\(name) isn't installed or couldn't be found."
        }
    }
}

/// Runs tools by absolute path with an argument list: never through a shell, so no
/// argument can be interpreted as shell syntax.
public struct Shell: Sendable {
    public let tools: ToolLocator
    public static let maxOutputBytes = 8_000_000

    public init(tools: ToolLocator) {
        self.tools = tools
    }

    /// Runs `tool` with `arguments`, stopping it after `timeout`. Cancelling the calling
    /// task terminates the process.
    public func run(_ tool: String, _ arguments: [String], timeout: Duration = .seconds(60)) async throws -> ToolOutput {
        guard let url = tools.url(for: tool) else { throw ShellError.toolNotFound(tool) }
        return try await Self.run(url, arguments, environment: tools.environment, timeout: timeout)
    }

    static func run(_ url: URL, _ arguments: [String], environment: [String: String], timeout: Duration) async throws -> ToolOutput {
        let job = Job(url, arguments, environment)
        try job.process.run()
        // Read both pipes while the process runs, so a full pipe can't block it.
        async let stdout = job.read(errorStream: false)
        async let stderr = job.read(errorStream: true)

        let deadline = ContinuousClock.now + timeout
        var timedOut = false
        await withTaskCancellationHandler {
            while job.process.isRunning {
                if ContinuousClock.now >= deadline { timedOut = true; job.process.terminate(); break }
                try? await Task.sleep(for: .milliseconds(50))
            }
        } onCancel: {
            job.process.terminate()
        }
        job.process.waitUntilExit()
        return ToolOutput(status: job.process.terminationStatus, stdout: await stdout, stderr: await stderr, timedOut: timedOut)
    }

    /// A process and its pipes. `Process` isn't Sendable; this box is safe because the
    /// process is only started once, then only queried, terminated or read from.
    private final class Job: @unchecked Sendable {
        let process = Process()
        let out = Pipe(), err = Pipe()

        init(_ url: URL, _ arguments: [String], _ environment: [String: String]) {
            process.executableURL = url
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out
            process.standardError = err
        }

        func read(errorStream: Bool) async -> String {
            await Task.detached { [self] in
                let data = (errorStream ? err : out).fileHandleForReading.readDataToEndOfFile()
                return String(decoding: data.prefix(Shell.maxOutputBytes), as: UTF8.self)
            }.value
        }
    }
}

/// Finds developer tools. GUI apps don't get the login shell's PATH, so this looks in the
/// login shell's PATH (read once), then in well-known install locations.
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
        let expand = { (p: String) in p.replacingOccurrences(of: "~", with: home).replacingOccurrences(of: "$USER", with: user) }
        var dirs: [String] = []
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let out = try? await Shell.run(URL(fileURLWithPath: shell), ["-ilc", "printf '\\n__PATH__%s\\n' \"$PATH\""],
                                          environment: ProcessInfo.processInfo.environment, timeout: .seconds(15)),
           let line = out.stdout.split(separator: "\n").first(where: { $0.hasPrefix("__PATH__") }) {
            dirs += line.dropFirst("__PATH__".count).split(separator: ":").map(String.init)
        }
        dirs += knownLocations.map(expand)
        var seen = Set<String>()
        let unique = dirs.filter { seen.insert($0).inserted }
        let clt = (try? await Shell.run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"], environment: [:], timeout: .seconds(10)))?.succeeded ?? false
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
