import AppKit
import Foundation
import GhosttyKit

enum CollectPanesShortcutSelftest {
    static let rootEnv = "GHOSTTY_COLLECT_PANES_SHORTCUT_SELFTEST_ROOT"

    struct Snapshot: Equatable, Sendable {
        let selectedTabIndex: Int
        let tabPaneIDs: [[String]]

        var tabs: Int { tabPaneIDs.count }
        var tab1Terminals: Int { tabPaneIDs.first?.count ?? 0 }
        var tab2Terminals: Int { tabPaneIDs.count > 1 ? tabPaneIDs[1].count : 0 }
        var flattenedPaneIDs: [String] { tabPaneIDs.flatMap { $0 } }
    }

    struct Report: Sendable {
        let pre: Snapshot
        let post: Snapshot
        let keyIsBinding: Bool
        let performKeyEquivalentHandled: Bool

        var passed: Bool {
            keyIsBinding &&
                performKeyEquivalentHandled &&
                pre.selectedTabIndex == 2 &&
                pre.tabPaneIDs.map(\.count) == [2, 2] &&
                post.selectedTabIndex == 1 &&
                post.tabPaneIDs.map(\.count) == [4] &&
                post.flattenedPaneIDs == pre.flattenedPaneIDs
        }

        func text(bindingFlags: Ghostty.Input.BindingFlags?) -> String {
            [
                "PRE_SELECTED_TAB=\(pre.selectedTabIndex)",
                "PRE_TABS=\(pre.tabs)",
                "PRE_TAB1_TERMINALS=\(pre.tab1Terminals)",
                "PRE_TAB2_TERMINALS=\(pre.tab2Terminals)",
                "PRE_TAB1_IDS=\(pre.tabPaneIDs.first?.joined(separator: ",") ?? "")",
                "PRE_TAB2_IDS=\(pre.tabPaneIDs.count > 1 ? pre.tabPaneIDs[1].joined(separator: ",") : "")",
                "KEY_IS_BINDING=\(keyIsBinding ? 1 : 0)",
                "BINDING_FLAGS=\(bindingFlags?.rawValue ?? 0)",
                "PERFORM_KEY_EQUIVALENT_HANDLED=\(performKeyEquivalentHandled ? 1 : 0)",
                "POST_SELECTED_TAB=\(post.selectedTabIndex)",
                "POST_TABS=\(post.tabs)",
                "POST_TAB1_TERMINALS=\(post.tab1Terminals)",
                "POST_TAB2_TERMINALS=\(post.tab2Terminals)",
                "POST_TAB1_IDS=\(post.tabPaneIDs.first?.joined(separator: ",") ?? "")",
                "POST_TAB2_IDS=\(post.tabPaneIDs.count > 1 ? post.tabPaneIDs[1].joined(separator: ",") : "")",
                "RESULT=\(passed ? "PASS" : "FAIL")",
            ].joined(separator: "\n") + "\n"
        }
    }

    enum SelftestError: LocalizedError {
        case missingWindow
        case missingFocusedSurface
        case splitCreationFailed
        case tabCreationFailed
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .missingWindow: "missing window during selftest"
            case .missingFocusedSurface: "missing focused surface during selftest"
            case .splitCreationFailed: "failed to create split during selftest"
            case .tabCreationFailed: "failed to create tab during selftest"
            case .timedOut(let detail): "selftest timed out waiting for \(detail)"
            }
        }
    }

    final class Runner {
        private weak var appDelegate: AppDelegate?
        private var started = false

        init(appDelegate: AppDelegate) {
            self.appDelegate = appDelegate
        }

        @MainActor
        func startIfNeeded() {
            guard !started else { return }
            guard rootURL != nil else { return }
            started = true

            Task {
                await self.run()
            }
        }

        private var rootURL: URL? {
            guard let path = ProcessInfo.processInfo.environment[CollectPanesShortcutSelftest.rootEnv], !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        @MainActor
        private func run() async {
            guard let appDelegate, let rootURL else { return }

            do {
                try FileManager.default.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                let report = try await perform(using: appDelegate)
                try report.text(bindingFlags: lastBindingFlags).write(
                    to: rootURL.appending(path: "report.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                writeFailure(error: error, to: rootURL)
            }

            NSApp.terminate(nil)
        }

        private var lastBindingFlags: Ghostty.Input.BindingFlags?

        @MainActor
        private func perform(using appDelegate: AppDelegate) async throws -> Report {
            let first = TerminalController.newWindow(appDelegate.ghostty)

            try await waitFor("first focused surface") {
                first.focusedSurface != nil && first.window != nil
            }

            guard let firstWindow = first.window else { throw SelftestError.missingWindow }
            guard let firstFocused = first.focusedSurface else { throw SelftestError.missingFocusedSurface }
            guard first.newSplit(at: firstFocused, direction: .right) != nil else {
                throw SelftestError.splitCreationFailed
            }

            try await waitFor("first tab split count") {
                first.surfaceTree.count == 2
            }

            guard let second = TerminalController.newTab(appDelegate.ghostty, from: firstWindow) else {
                throw SelftestError.tabCreationFailed
            }

            try await waitFor("second tab creation") {
                self.snapshot(for: firstWindow)?.tabPaneIDs.count == 2 &&
                    second.focusedSurface != nil
            }

            guard let secondFocused = second.focusedSurface else { throw SelftestError.missingFocusedSurface }
            guard second.newSplit(at: secondFocused, direction: .right) != nil else {
                throw SelftestError.splitCreationFailed
            }

            try await waitFor("pre shortcut snapshot") {
                self.snapshot(for: firstWindow)?.tabPaneIDs.map(\.count) == [2, 2]
            }

            guard let shortcutTargetView = second.focusedSurface else {
                throw SelftestError.missingFocusedSurface
            }

            second.focusSurface(shortcutTargetView)
            try await waitFor("focused surface appkit focus") {
                shortcutTargetView.focused
            }

            guard let pre = snapshot(for: firstWindow) else { throw SelftestError.missingWindow }
            guard let targetSurface = shortcutTargetView.surfaceModel,
                  let shortcutEvent = shortcutEvent(for: shortcutTargetView)
            else {
                throw SelftestError.missingFocusedSurface
            }

            lastBindingFlags = bindingFlags(for: shortcutEvent, on: targetSurface)
            let handled = shortcutTargetView.performKeyEquivalent(with: shortcutEvent)

            try await waitFor("post shortcut collapse") {
                guard let snapshot = self.snapshot(for: firstWindow) else { return false }
                return snapshot.selectedTabIndex == 1 && snapshot.tabPaneIDs.map(\.count) == [4]
            }

            guard let post = snapshot(for: firstWindow) else { throw SelftestError.missingWindow }
            return Report(
                pre: pre,
                post: post,
                keyIsBinding: lastBindingFlags != nil,
                performKeyEquivalentHandled: handled
            )
        }

        @MainActor
        private func shortcutEvent(for targetView: Ghostty.SurfaceView) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .control],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: targetView.window?.windowNumber ?? 0,
                context: nil,
                characters: "1",
                charactersIgnoringModifiers: "1",
                isARepeat: false,
                keyCode: UInt16(Ghostty.Input.Key.digit1.keyCode ?? 18)
            )
        }

        @MainActor
        private func snapshot(for primaryWindow: NSWindow) -> Snapshot? {
            if let tabGroup = primaryWindow.tabGroup {
                let controllers = tabGroup.windows.compactMap { $0.windowController as? TerminalController }
                guard !controllers.isEmpty else { return nil }

                let selectedIndex = tabGroup.selectedWindow.flatMap { selected in
                    tabGroup.windows.firstIndex(of: selected).map { $0 + 1 }
                } ?? 1

                return Snapshot(
                    selectedTabIndex: selectedIndex,
                    tabPaneIDs: controllers.map { controller in
                        controller.surfaceTree.map { $0.id.uuidString }
                    }
                )
            }

            guard let controller = primaryWindow.windowController as? TerminalController else { return nil }
            return Snapshot(
                selectedTabIndex: 1,
                tabPaneIDs: [controller.surfaceTree.map { $0.id.uuidString }]
            )
        }

        @MainActor
        private func bindingFlags(
            for event: NSEvent,
            on surface: Ghostty.Surface
        ) -> Ghostty.Input.BindingFlags? {
            var ghosttyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
            return (event.characters ?? "").withCString { ptr in
                ghosttyEvent.text = ptr
                return surface.keyIsBinding(ghosttyEvent)
            }
        }

        @MainActor
        private func waitFor(
            _ label: String,
            timeoutSeconds: Double = 5.0,
            condition: @escaping @MainActor () -> Bool
        ) async throws {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while Date() < deadline {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(100))
            }

            throw SelftestError.timedOut(label)
        }

        private func writeFailure(error: Error, to rootURL: URL?) {
            guard let rootURL else { return }

            let message = [
                "RESULT=FAIL",
                "ERROR=\(error.localizedDescription)",
            ].joined(separator: "\n") + "\n"

            try? message.write(
                to: rootURL.appending(path: "report.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
    }
}
