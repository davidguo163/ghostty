import AppKit
import Foundation

enum RemotePasteBridge {
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

    private static let remoteHost =
        ProcessInfo.processInfo.environment["GHOSTTY_REMOTE_PASTE_HOST"] ?? "dev"
    private static let remoteTmuxRootSuffix = ".tmux"

    static func remotePastePath(for pasteboard: NSPasteboard) throws -> String? {
        if let fileURL = singleFileURL(from: pasteboard) {
            return try uploadFile(fileURL)
        }

        if let imageData = clipboardImageData(from: pasteboard) {
            return try uploadImageData(imageData)
        }

        return nil
    }

    private static func singleFileURL(from pasteboard: NSPasteboard) -> URL? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.count == 1,
           let url = urls.first,
           url.isFileURL {
            return url
        }

        guard let raw = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            !raw.contains("\n")
        else {
            return nil
        }

        if let url = URL(string: raw), url.isFileURL {
            return url
        }

        let expanded = NSString(string: raw).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            return URL(fileURLWithPath: expanded)
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

    private static func uploadFile(_ fileURL: URL) throws -> String {
        let remoteHome = try resolvedRemoteHome()
        let timestamp = timestampString()
        let basename = sanitizeFilename(fileURL.lastPathComponent.isEmpty ? "attachment" : fileURL.lastPathComponent)
        let remoteDir = "\(remoteHome)/\(remoteTmuxRootSuffix)/paste-files"
        let remotePath = "\(remoteDir)/\(timestamp)-\(basename)"

        try ensureRemoteDirectory(remoteDir)
        try runProcess(
            "/usr/bin/scp",
            ["-q", fileURL.path, "\(remoteHost):\(remotePath)"],
            failurePrefix: "scp file upload failed"
        )

        return Ghostty.Shell.escape(remotePath)
    }

    private static func uploadImageData(_ imageData: Data) throws -> String {
        let remoteHome = try resolvedRemoteHome()
        let timestamp = timestampString()
        let remoteDir = "\(remoteHome)/\(remoteTmuxRootSuffix)/paste-images"
        let remotePath = "\(remoteDir)/paste-\(timestamp).png"
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-remote-paste-\(UUID().uuidString).png")

        try imageData.write(to: localURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: localURL) }

        try ensureRemoteDirectory(remoteDir)
        try runProcess(
            "/usr/bin/scp",
            ["-q", localURL.path, "\(remoteHost):\(remotePath)"],
            failurePrefix: "scp image upload failed"
        )

        return Ghostty.Shell.escape(remotePath)
    }

    private static func ensureRemoteDirectory(_ remoteDir: String) throws {
        try runProcess(
            "/usr/bin/ssh",
            [remoteHost, "mkdir", "-p", remoteDir],
            failurePrefix: "remote directory bootstrap failed"
        )
    }

    private static func resolvedRemoteHome() throws -> String {
        let output = try runProcess(
            "/usr/bin/ssh",
            [remoteHost, "sh", "-lc", "printf %s \"$HOME\""],
            failurePrefix: "remote home lookup failed",
            captureStdout: true
        )
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw BridgeError.remoteHomeUnavailable }
        return value
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
        process.standardError = stderrPipe
        process.standardOutput = captureStdout ? stdoutPipe : nil

        try process.run()
        process.waitUntilExit()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            let detail = stderr.isEmpty ? "exit \(process.terminationStatus)" : stderr
            throw BridgeError.processFailed("\(failurePrefix): \(detail)")
        }

        if captureStdout {
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
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
