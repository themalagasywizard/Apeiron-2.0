import Foundation

public struct ShellResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var timedOut: Bool
    public var duration: TimeInterval
}

/// Runs shell commands with a timeout, cancellation and bounded output.
public enum Shell {
    public static var defaultShell: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: shell),
           shell.hasSuffix("zsh") || shell.hasSuffix("bash") {
            return shell
        }
        return FileManager.default.isExecutableFile(atPath: "/bin/zsh") ? "/bin/zsh" : "/bin/bash"
    }

    public static func run(
        _ command: String,
        in directory: URL,
        timeout: TimeInterval = 120,
        stdin: Data? = nil,
        environment: [String: String] = [:],
        maxOutputBytes: Int = 4_000_000
    ) async throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: defaultShell)
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["APEIRON"] = "1"
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        env["GIT_PAGER"] = "cat"
        env["PAGER"] = "cat"
        for (key, value) in environment { env[key] = value }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let collector = OutputCollector(limit: maxOutputBytes)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.append(data, toStdout: true) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.append(data, toStdout: false) }
        }

        let start = Date()
        let exit = ExitBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ShellResult, Error>) in
                process.terminationHandler = { finished in
                    // Give the readability handlers a moment to drain the pipes.
                    // We never block on EOF: a backgrounded child may hold the
                    // pipe open indefinitely.
                    Thread.sleep(forTimeInterval: 0.12)
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    let (out, err) = collector.strings()
                    continuation.resume(returning: ShellResult(
                        stdout: out,
                        stderr: err,
                        exitCode: finished.terminationStatus,
                        timedOut: exit.timedOut,
                        duration: Date().timeIntervalSince(start)
                    ))
                }
                do {
                    try process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                if let stdin {
                    stdinPipe.fileHandleForWriting.write(stdin)
                }
                try? stdinPipe.fileHandleForWriting.close()

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        exit.timedOut = true
                        stop(process, grace: 2)
                    }
                }
            }
        } onCancel: {
            stop(process, grace: 0.3)
        }
    }

    /// Asks a process to stop, then kills it and its children if it doesn't.
    /// (Signals can be masked in the child, so SIGTERM alone isn't enough.)
    static func stop(_ process: Process, grace: TimeInterval) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            guard process.isRunning else { return }
            killChildren(of: pid)
            kill(pid, SIGKILL)
        }
    }

    private static func killChildren(of pid: Int32) {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: "/usr/bin/pkill") ? "/usr/bin/pkill" : "/bin/pkill")
        pkill.arguments = ["-KILL", "-P", String(pid)]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    /// Finds an executable on PATH.
    public static func which(_ name: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin")
            .split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        for directory in paths {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

private final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _timedOut = false
    var timedOut: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _timedOut }
        set { lock.lock(); _timedOut = newValue; lock.unlock() }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var dropped = 0
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ data: Data, toStdout: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let used = stdout.count + stderr.count
        let room = max(0, limit - used)
        let accepted = data.prefix(room)
        dropped += data.count - accepted.count
        if toStdout { stdout.append(accepted) } else { stderr.append(accepted) }
    }

    func strings() -> (String, String) {
        lock.lock()
        defer { lock.unlock() }
        var out = String(decoding: stdout, as: UTF8.self)
        if dropped > 0 { out += "\n[output capped: \(dropped) more bytes discarded]" }
        return (out, String(decoding: stderr, as: UTF8.self))
    }
}
