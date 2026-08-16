import Foundation

struct CommandResult {
    let terminationStatus: Int32
    let output: String
}

enum ProcessRunnerError: LocalizedError {
    case couldNotStart(String)
    case commandFailed(executable: String, status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .couldNotStart(let message):
            return L10n.format("Could not start the command: %@", message)
        case .commandFailed(let executable, let status, let output):
            let usefulOutput = CommandFailureSummary.text(from: output)
            return usefulOutput.isEmpty
                ? L10n.format("The %@ command failed (code %d).", executable, status)
                : L10n.format(
                    "The %@ command failed (code %d).\n%@\n\nOpen Activity details for the complete command output.",
                    executable,
                    status,
                    usefulOutput
                )
        }
    }
}

enum CommandFailureSummary {
    private static let maximumDiagnosticLines = 12
    private static let maximumFallbackLines = 20

    static func text(from output: String) -> String {
        let lines = output
            .split(whereSeparator: \Character.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let diagnostics = uniqueLines(lines.filter(isDiagnostic))
        if !diagnostics.isEmpty {
            return diagnostics.suffix(maximumDiagnosticLines).joined(separator: "\n")
        }
        let meaningfulLines = lines.filter {
            !$0.hasPrefix("export ") && !$0.hasPrefix("cd ")
        }
        return meaningfulLines.suffix(maximumFallbackLines).joined(separator: "\n")
    }

    private static func isDiagnostic(_ line: String) -> Bool {
        let normalized = line.lowercased()
        return normalized.hasPrefix("error:")
            || normalized.contains(": error:")
            || normalized.contains("fatal error:")
            || normalized.hasPrefix("** build failed **")
            || normalized.hasPrefix("** archive failed **")
            || normalized.hasPrefix("** export failed **")
    }

    private static func uniqueLines(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }
}

final class ProcessRunner {
    typealias OutputHandler = @Sendable (String) -> Void

    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        additionalEnvironment: [String: String] = [:],
        onOutput: OutputHandler? = nil
    ) async throws -> CommandResult {
        let cancellationController = ProcessCancellationController()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let outputPipe = Pipe()
                let buffer = ThreadSafeTextBuffer()

                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                process.standardOutput = outputPipe
                process.standardError = outputPipe

                var environment = ProcessInfo.processInfo.environment
                let commonToolPaths = [
                    "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                    "/bin", "/usr/sbin", "/sbin"
                ]
                let existingPath = environment["PATH"] ?? ""
                environment["PATH"] = (commonToolPaths + [existingPath])
                    .filter { !$0.isEmpty }
                    .joined(separator: ":")
                additionalEnvironment.forEach { environment[$0.key] = $0.value }
                process.environment = environment

                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty,
                          let text = String(data: data, encoding: .utf8)
                    else {
                        return
                    }
                    buffer.append(text)
                    onOutput?(text)
                }

                process.terminationHandler = { finishedProcess in
                    cancellationController.finished(finishedProcess)
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    let remainingData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    if let remainingText = String(data: remainingData, encoding: .utf8),
                       !remainingText.isEmpty {
                        buffer.append(remainingText)
                        onOutput?(remainingText)
                    }

                    continuation.resume(returning: CommandResult(
                        terminationStatus: finishedProcess.terminationStatus,
                        output: buffer.value
                    ))
                }

                do {
                    try process.run()
                    cancellationController.started(process)
                } catch {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(
                        throwing: ProcessRunnerError.couldNotStart(error.localizedDescription)
                    )
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancellationController.cancel()
        }
    }

    func runAndRequireSuccess(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        additionalEnvironment: [String: String] = [:],
        onOutput: OutputHandler? = nil
    ) async throws -> CommandResult {
        let result = try await run(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            additionalEnvironment: additionalEnvironment,
            onOutput: onOutput
        )

        guard result.terminationStatus == 0 else {
            throw ProcessRunnerError.commandFailed(
                executable: executable.lastPathComponent,
                status: result.terminationStatus,
                output: result.output
            )
        }
        return result
    }
}

private final class ProcessCancellationController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationWasRequested = false

    func started(_ process: Process) {
        lock.lock()
        if cancellationWasRequested {
            lock.unlock()
            stop(process)
        } else {
            self.process = process
            lock.unlock()
        }
    }

    func finished(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancellationWasRequested = true
        let process = process
        lock.unlock()

        if let process {
            stop(process)
        }
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

private final class ThreadSafeTextBuffer {
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) {
        lock.lock()
        storage.append(text)
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
