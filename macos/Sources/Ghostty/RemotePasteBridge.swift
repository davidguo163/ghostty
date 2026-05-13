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
    private static let webpQuality: Double = 0.85
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

        let fileData = try Data(contentsOf: fileURL)
        try uploadDataOneShot(
            payload: fileData,
            host: host,
            remoteDir: remoteDir,
            remotePath: remotePath
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

        let payload: Data
        let ext: String
        if let webp = encodeWebP(imageData, quality: webpQuality), webp.count < imageData.count {
            payload = webp
            ext = "webp"
        } else {
            payload = imageData
            ext = "png"
        }

        let remotePath = "\(remoteDir)/paste-\(timestamp).\(ext)"
        try uploadDataOneShot(
            payload: payload,
            host: host,
            remoteDir: remoteDir,
            remotePath: remotePath
        )

        return Ghostty.Shell.escape(remotePath)
    }

    // Single-SSH-session upload: mkdir + write + atomic rename in one remote
    // shell. Cuts paste latency in half on slow-fork hosts because the legacy
    // path opened two SSH sessions (mkdir then scp), and each session fork on
    // the remote dominated the wall time.
    private static func uploadDataOneShot(
        payload: Data,
        host: String,
        remoteDir: String,
        remotePath: String
    ) throws {
        let quotedDir = posixSingleQuote(remoteDir)
        let quotedTmp = posixSingleQuote(remotePath + ".part")
        let quotedFinal = posixSingleQuote(remotePath)
        let script = "set -e; mkdir -p \(quotedDir); cat > \(quotedTmp); mv \(quotedTmp) \(quotedFinal)"

        var arguments = sshOptions
        arguments.append(host)
        arguments.append(script)

        _ = try runProcess(
            "/usr/bin/ssh",
            arguments,
            failurePrefix: "remote paste upload failed",
            stdinData: payload
        )
    }

    private static func posixSingleQuote(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // macOS ImageIO does not ship a WebP encoder (only a decoder), so we shell
    // out to the libwebp `cwebp` binary. Falls back to nil when cwebp is not
    // installed, which makes the caller keep the original PNG payload.
    private static func encodeWebP(_ source: Data, quality: Double) -> Data? {
        guard let cwebpPath = locateCWebP() else { return nil }

        let tmpDir = FileManager.default.temporaryDirectory
        let uuid = UUID().uuidString
        let inputURL = tmpDir.appendingPathComponent("ghostty-webp-in-\(uuid).png")
        let outputURL = tmpDir.appendingPathComponent("ghostty-webp-out-\(uuid).webp")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        do {
            try source.write(to: inputURL, options: .atomic)
            let qualityArg = String(Int((quality * 100).rounded()))
            _ = try runProcess(
                cwebpPath,
                ["-q", qualityArg, "-quiet", inputURL.path, "-o", outputURL.path],
                failurePrefix: "cwebp encode failed"
            )
            return try Data(contentsOf: outputURL)
        } catch {
            return nil
        }
    }

    private static func locateCWebP() -> String? {
        let candidates = [
            "/opt/homebrew/bin/cwebp",
            "/usr/local/bin/cwebp",
            "/opt/local/bin/cwebp",
        ]
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
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

    private static func runProcess(
        _ executable: String,
        _ arguments: [String],
        failurePrefix: String,
        captureStdout: Bool = false,
        stdinData: Data? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Optional stdin: must be writen on a background queue so the parent
        // doesn't deadlock when the payload exceeds the pipe buffer (~64KB).
        let stdinPipe: Pipe?
        if stdinData != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        try process.run()

        if let data = stdinData, let pipe = stdinPipe {
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = pipe.fileHandleForWriting
                handle.write(data)
                try? handle.close()
            }
        }

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
