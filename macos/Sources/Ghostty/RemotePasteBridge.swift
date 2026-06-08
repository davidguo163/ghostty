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
    // Timing instrumentation, gated on env var so it's free in production.
    // Set GHOSTTY_PASTE_TIMING=1 in launchctl/Info.plist or via `open -a` env
    // injection to enable, then watch with:
    //     log stream --predicate 'subsystem == "ghostty.paste"'
    private static let timingEnabled = ProcessInfo.processInfo
        .environment["GHOSTTY_PASTE_TIMING"] != nil
    private static func tlog(_ label: String) {
        guard timingEnabled else { return }
        NSLog("[paste-timing] %.6f %@", Date().timeIntervalSince1970, label)
    }

    static func preparePaste(for pasteboard: NSPasteboard) throws -> PasteRequest {
        tlog("preparePaste start")
        defer { tlog("preparePaste end") }

        if let fileURL = singleFileURL(from: pasteboard) {
            return .remote(.file(fileURL))
        }

        tlog("preparePaste before clipboardImageData")
        if let imageData = clipboardImageData(from: pasteboard) {
            tlog("preparePaste after clipboardImageData (\(imageData.count) bytes)")
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
        tlog("uploadRemotePath start")
        defer { tlog("uploadRemotePath end") }

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
        let timestamp = timestampString()
        let basename = sanitizeFilename(fileURL.lastPathComponent.isEmpty ? "attachment" : fileURL.lastPathComponent)
        let subdir = "\(remoteTmuxRootSuffix)/paste-files"
        let filename = "\(timestamp)-\(basename)"

        let fileData = try Data(contentsOf: fileURL)
        let remotePath = try uploadDataOneShot(
            payload: fileData,
            host: host,
            subdir: subdir,
            filename: filename
        )

        return Ghostty.Shell.escape(remotePath)
    }

    private static func uploadImageData(
        _ imageData: Data,
        configuredHost: String?
    ) throws -> String {
        tlog("uploadImageData start (\(imageData.count) bytes in)")
        let host = resolvedRemoteHost(configuredHost: configuredHost)
        tlog("uploadImageData: resolved host=\(host)")
        let timestamp = timestampString()
        let subdir = "\(remoteTmuxRootSuffix)/paste-images"

        tlog("uploadImageData: encodeWebP start")
        let payload: Data
        let ext: String
        if let webp = encodeWebP(imageData, quality: webpQuality), webp.count < imageData.count {
            tlog("uploadImageData: encodeWebP done (\(webp.count) bytes)")
            payload = webp
            ext = "webp"
        } else {
            tlog("uploadImageData: encodeWebP fallback to PNG")
            payload = imageData
            ext = "png"
        }

        let filename = "paste-\(timestamp).\(ext)"
        tlog("uploadImageData: uploadDataOneShot start")
        let remotePath = try uploadDataOneShot(
            payload: payload,
            host: host,
            subdir: subdir,
            filename: filename
        )
        tlog("uploadImageData: uploadDataOneShot done")

        return Ghostty.Shell.escape(remotePath)
    }

    // Single-SSH-session upload: the remote shell expands $HOME itself, so we
    // skip the previous `ssh HOST printenv HOME` round-trip (which cost
    // ~600ms on a slow-fork host). The script does mkdir + atomic write +
    // rename in one fork, then echoes the absolute remote path back so the
    // caller doesn't need to know what $HOME resolved to.
    //
    // subdir and filename are expected to contain only [A-Za-z0-9._/-] so
    // they're safe to embed unquoted in the remote bash; if that ever
    // changes, add posix-single-quoting here.
    private static func uploadDataOneShot(
        payload: Data,
        host: String,
        subdir: String,
        filename: String
    ) throws -> String {
        let script = """
        set -e
        D="$HOME/\(subdir)"
        mkdir -p "$D"
        P="$D/\(filename)"
        cat > "$P.part"
        mv "$P.part" "$P"
        printf %s "$P"
        """

        var arguments = sshOptions
        arguments.append(host)
        arguments.append(script)

        let stdout = try runProcess(
            "/usr/bin/ssh",
            arguments,
            failurePrefix: "remote paste upload failed",
            captureStdout: true,
            stdinData: payload,
            timeout: nil
        )
        let path = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw BridgeError.processFailed("remote paste upload returned empty path")
        }
        return path
    }

    // macOS ImageIO does not ship a WebP encoder (only a decoder), so we shell
    // out to the libwebp `cwebp` binary. Falls back to nil when cwebp is not
    // installed, which makes the caller keep the original PNG payload.
    private static func encodeWebP(_ source: Data, quality: Double) -> Data? {
        tlog("encodeWebP start (\(source.count) bytes)")
        defer { tlog("encodeWebP end") }
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
            tlog("encodeWebP: wrote input PNG")
            let qualityArg = String(Int((quality * 100).rounded()))
            _ = try runProcess(
                cwebpPath,
                ["-q", qualityArg, "-quiet", inputURL.path, "-o", outputURL.path],
                failurePrefix: "cwebp encode failed"
            )
            tlog("encodeWebP: cwebp returned")
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

    /// `timeout` is a wall-clock cap in seconds. Pass `nil` to wait without a
    /// limit: required for the upload step, whose elapsed time scales with the
    /// payload size (a 60MB+ file streamed over the one SSH session easily
    /// exceeds any fixed budget). A stalled connection is still caught quickly
    /// by the ssh-level ConnectTimeout / ServerAliveInterval options, so an
    /// unbounded wait only blocks while the transfer is making progress.
    private static func runProcess(
        _ executable: String,
        _ arguments: [String],
        failurePrefix: String,
        captureStdout: Bool = false,
        stdinData: Data? = nil,
        timeout: Double? = commandTimeoutSeconds
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

        tlog("runProcess: about to .run() \((executable as NSString).lastPathComponent)")
        try process.run()
        tlog("runProcess: .run() returned (pid=\(process.processIdentifier))")

        if let data = stdinData, let pipe = stdinPipe {
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = pipe.fileHandleForWriting
                handle.write(data)
                try? handle.close()
                Self.tlog("runProcess: stdin write done (\(data.count) bytes)")
            }
        }

        if let timeout {
            let waitResult = finished.wait(
                timeout: .now() + .milliseconds(Int(timeout * 1000))
            )
            tlog("runProcess: process exited (status=\(process.terminationStatus))")
            if waitResult == .timedOut {
                process.terminate()
                _ = finished.wait(timeout: .now() + .seconds(2))
                throw BridgeError.processFailed("\(failurePrefix): timed out")
            }
        } else {
            finished.wait()
            tlog("runProcess: process exited (status=\(process.terminationStatus))")
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
