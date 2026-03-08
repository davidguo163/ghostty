import AppKit
import Foundation

enum RemotePasteBridge {
    enum PasteRequest: Sendable {
        case native
        case remote(RemotePayload)
    }

    enum RemotePayload: Sendable {
        case file(URL)
        case image(Data)
    }

    enum BridgeError: LocalizedError {
        case unsupportedImage
        case remoteHomeUnavailable
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedImage:
                return "Clipboard image could not be converted to PNG."
            case .remoteHomeUnavailable:
                return "Could not determine the remote home directory for the paste bridge."
            case let .processFailed(message):
                return message
            }
        }
    }

    private static let defaultRemoteHost = "dev"
    private static let remoteTmuxRootSuffix = ".tmux"
    private static let commandTimeoutSeconds = 15.0
    private static let sshOptions = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=5",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "ServerAliveInterval=5",
        "-o", "ServerAliveCountMax=1",
    ]
    private static let stateQueue = DispatchQueue(label: "Ghostty.RemotePasteBridge.State")
    private static var cachedRemoteHomes: [String: String] = [:]

    static func preparePaste(for pasteboard: NSPasteboard) throws -> PasteRequest {
        if let fileURL = singleFileURL(from: pasteboard) {
            return .remote(.file(fileURL))
        }

        if let imageData = clipboardImageData(from: pasteboard) {
            return .remote(.image(imageData))
        }

        if hasPotentialImageData(in: pasteboard) {
            throw BridgeError.unsupportedImage
        }

        return .native
    }

    static func uploadRemotePath(
        for payload: RemotePayload,
        configuredHost: String?
    ) throws -> String {
        switch payload {
        case let .file(fileURL):
            return try uploadFile(fileURL, configuredHost: configuredHost)
        case let .image(imageData):
            return try uploadImageData(imageData, configuredHost: configuredHost)
        }
    }

    static func testingRemoteHome(configuredHost: String?) throws -> String {
        let host = resolvedRemoteHost(configuredHost: configuredHost)
        return try resolvedRemoteHome(host: host)
    }

    static func testingRemoteFileExists(
        at path: String,
        configuredHost: String?
    ) throws -> Bool {
        let output = try runRemoteShell(
            "if [ -f \(Ghostty.Shell.escape(path)) ]; then printf yes; else printf no; fi",
            configuredHost: configuredHost,
            failurePrefix: "remote file existence check failed"
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
    }

    static func testingRemoteFileHasContent(
        at path: String,
        configuredHost: String?
    ) throws -> Bool {
        let output = try runRemoteShell(
            "if [ -s \(Ghostty.Shell.escape(path)) ]; then printf yes; else printf no; fi",
            configuredHost: configuredHost,
            failurePrefix: "remote file size check failed"
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
    }

    static func testingRemoteFileContents(
        at path: String,
        configuredHost: String?
    ) throws -> String {
        try runRemoteShell(
            "cat \(Ghostty.Shell.escape(path))",
            configuredHost: configuredHost,
            failurePrefix: "remote file read failed"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func singleFileURL(from pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           urls.count == 1,
           let url = urls.first,
           url.isFileURL {
            return url
        }

        if let raw = pasteboard.string(forType: .fileURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: raw),
           url.isFileURL {
            return url
        }

        return nil
    }

    private static func clipboardImageData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) {
            return png
        }

        if let tiff = pasteboard.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            return png
        }

        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            return png
        }

        return nil
    }

    private static func hasPotentialImageData(in pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if types.contains(.png) || types.contains(.tiff) {
            return true
        }

        return pasteboard.canReadObject(forClasses: [NSImage.self], options: [:])
    }

    private static func uploadFile(
        _ fileURL: URL,
        configuredHost: String?
    ) throws -> String {
        let host = resolvedRemoteHost(configuredHost: configuredHost)
        let remoteHome = try resolvedRemoteHome(host: host)
        let timestamp = timestampString()
        let basename = sanitizeFilename(fileURL.lastPathComponent.isEmpty ? "attachment" : fileURL.lastPathComponent)
        let remoteDir = "\(remoteHome)/\(remoteTmuxRootSuffix)/paste-files"
        let remotePath = "\(remoteDir)/\(timestamp)-\(basename)"

        try ensureRemoteDirectory(remoteDir, host: host)
        try runProcess(
            "/usr/bin/scp",
            ["-q", fileURL.path, "\(host):\(remotePath)"],
            failurePrefix: "scp file upload failed"
        )

        return Ghostty.Shell.escape(remotePath)
    }

    private static func uploadImageData(
        _ imageData: Data,
        configuredHost: String?
    ) throws -> String {
        let host = resolvedRemoteHost(configuredHost: configuredHost)
        let remoteHome = try resolvedRemoteHome(host: host)
        let timestamp = timestampString()
        let remoteDir = "\(remoteHome)/\(remoteTmuxRootSuffix)/paste-images"
        let remotePath = "\(remoteDir)/paste-\(timestamp).png"
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-remote-paste-\(UUID().uuidString).png")

        try imageData.write(to: localURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: localURL) }

        try ensureRemoteDirectory(remoteDir, host: host)
        try runProcess(
            "/usr/bin/scp",
            ["-q", localURL.path, "\(host):\(remotePath)"],
            failurePrefix: "scp image upload failed"
        )

        return Ghostty.Shell.escape(remotePath)
    }

    private static func ensureRemoteDirectory(_ remoteDir: String, host: String) throws {
        var arguments = sshOptions
        arguments.append(host)
        arguments.append(contentsOf: ["mkdir", "-p", remoteDir])
        try runProcess(
            "/usr/bin/ssh",
            arguments,
            failurePrefix: "remote directory bootstrap failed"
        )
    }

    private static func resolvedRemoteHome(host: String) throws -> String {
        if let cached = stateQueue.sync(execute: { cachedRemoteHomes[host] }) {
            return cached
        }

        var arguments = sshOptions
        arguments.append(host)
        arguments.append(contentsOf: ["printenv", "HOME"])
        let output = try runProcess(
            "/usr/bin/ssh",
            arguments,
            failurePrefix: "remote home lookup failed",
            captureStdout: true
        )
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw BridgeError.remoteHomeUnavailable }
        stateQueue.sync {
            cachedRemoteHomes[host] = value
        }
        return value
    }

    private static func runRemoteShell(
        _ command: String,
        configuredHost: String?,
        failurePrefix: String
    ) throws -> String {
        let host = resolvedRemoteHost(configuredHost: configuredHost)
        var arguments = sshOptions
        arguments.append(host)
        arguments.append("sh -lc \(singleQuote(command))")
        return try runProcess(
            "/usr/bin/ssh",
            arguments,
            failurePrefix: failurePrefix,
            captureStdout: true
        )
    }

    private static func resolvedRemoteHost(configuredHost: String?) -> String {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["GHOSTTY_REMOTE_PASTE_HOST"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }

        if let configured = configuredHost?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return configured
        }

        return defaultRemoteHost
    }

    private static func singleQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    @discardableResult
    private static func runProcess(
        _ executable: String,
        _ arguments: [String],
        failurePrefix: String,
        captureStdout: Bool = false
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        try process.run()
        let waitResult = finished.wait(
            timeout: .now() + .milliseconds(Int(commandTimeoutSeconds * 1000))
        )
        if waitResult == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + .seconds(2))
            throw BridgeError.processFailed("\(failurePrefix): timed out")
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            let detail = stderr.isEmpty ? "exit \(process.terminationStatus)" : stderr
            throw BridgeError.processFailed("\(failurePrefix): \(detail)")
        }

        if captureStdout {
            return String(data: stdoutData, encoding: .utf8) ?? ""
        }

        return ""
    }

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func sanitizeFilename(_ value: String) -> String {
        let sanitized = value.map { ch -> Character in
            switch ch {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-":
                return ch
            default:
                return "_"
            }
        }

        let collapsed = String(sanitized)
            .replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))

        return collapsed.isEmpty ? "attachment" : collapsed
    }
}
