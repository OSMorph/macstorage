import Foundation

struct CommandResult {
    var command: String
    var exitCode: Int32?
    var stdout: String
    var stderr: String
    var duration: TimeInterval
    var timedOut: Bool
    var launchError: String?

    var succeeded: Bool { exitCode == 0 && !timedOut && launchError == nil }
}

/// Runs read-only commands for the probe. Blocking: call it off the main thread.
enum Shell {
    static let maxOutputBytes = 2_000_000

    static func run(_ command: String, environment: [String: String], timeout: TimeInterval) -> CommandResult {
        let start = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        let reads = DispatchGroup()
        let lock = NSLock()
        var outData = Data()
        var errData = Data()
        reads.enter()
        DispatchQueue.global().async {
            let d = outPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); outData = d; lock.unlock()
            reads.leave()
        }
        reads.enter()
        DispatchQueue.global().async {
            let d = errPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); errData = d; lock.unlock()
            reads.leave()
        }

        do {
            try process.run()
        } catch {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            return CommandResult(command: command, exitCode: nil, stdout: "", stderr: "",
                                 duration: 0, timedOut: false, launchError: error.localizedDescription)
        }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
        }
        // A grandchild that keeps the pipe open must not hang the probe.
        _ = reads.wait(timeout: .now() + 3)

        lock.lock()
        let out = decode(outData)
        let err = decode(errData)
        lock.unlock()

        return CommandResult(command: command,
                             exitCode: process.isRunning ? nil : process.terminationStatus,
                             stdout: out, stderr: err,
                             duration: Date().timeIntervalSince(start),
                             timedOut: timedOut, launchError: nil)
    }

    private static func decode(_ data: Data) -> String {
        if data.count > maxOutputBytes {
            let head = String(decoding: data.prefix(maxOutputBytes), as: UTF8.self)
            return head + "\n[... truncated, \(data.count) bytes total]"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Single-quotes a value for /bin/sh.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
