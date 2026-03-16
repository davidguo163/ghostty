import Testing
import Foundation
@testable import Ghostty

@Suite
struct MainMenuTests {
    @Test func windowMenuIncludesCollectAllPanesIntoFirstTab() throws {
        let xib = try String(contentsOf: mainMenuURL(), encoding: .utf8)
        let selector = #selector(TerminalController.collectAllPanesIntoFirstTab(_:))

        #expect(xib.contains(#"title="Collect All Panes Into First Tab""#))
        #expect(xib.contains(#"selector="collectAllPanesIntoFirstTab:""#))
        #expect(NSStringFromSelector(selector) == "collectAllPanesIntoFirstTab:")
        #expect(TerminalController.instancesRespond(to: selector))
    }

    private func mainMenuURL(filePath: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(filePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/App/macOS/MainMenu.xib")
    }
}
