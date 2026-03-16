import Testing
@testable import Ghostty

@Suite
struct CollectPanesShortcutSelftestTests {
    @Test func reportPassesForCollapsedSingleTabWithFourPanes() {
        let report = CollectPanesShortcutSelftest.Report(
            pre: .init(selectedTabIndex: 2, tabPaneIDs: [["a", "b"], ["c", "d"]]),
            post: .init(selectedTabIndex: 1, tabPaneIDs: [["a", "b", "c", "d"]]),
            keyIsBinding: true,
            performKeyEquivalentHandled: true
        )

        #expect(report.passed)
    }

    @Test func reportFailsWhenShortcutDidNotMatchBinding() {
        let report = CollectPanesShortcutSelftest.Report(
            pre: .init(selectedTabIndex: 2, tabPaneIDs: [["a", "b"], ["c", "d"]]),
            post: .init(selectedTabIndex: 1, tabPaneIDs: [["a", "b", "c", "d"]]),
            keyIsBinding: false,
            performKeyEquivalentHandled: true
        )

        #expect(!report.passed)
    }

    @Test func reportFailsWhenTabsDidNotCollapse() {
        let report = CollectPanesShortcutSelftest.Report(
            pre: .init(selectedTabIndex: 2, tabPaneIDs: [["a", "b"], ["c", "d"]]),
            post: .init(selectedTabIndex: 2, tabPaneIDs: [["a", "b"], ["c", "d"]]),
            keyIsBinding: true,
            performKeyEquivalentHandled: true
        )

        #expect(!report.passed)
    }

    @Test func reportFailsWhenPaneIdentityChanges() {
        let report = CollectPanesShortcutSelftest.Report(
            pre: .init(selectedTabIndex: 2, tabPaneIDs: [["a", "b"], ["c", "d"]]),
            post: .init(selectedTabIndex: 1, tabPaneIDs: [["w", "x", "y", "z"]]),
            keyIsBinding: true,
            performKeyEquivalentHandled: true
        )

        #expect(!report.passed)
    }

    @Test func reportFailsWhenPerformKeyEquivalentDidNotHandleTheShortcut() {
        let report = CollectPanesShortcutSelftest.Report(
            pre: .init(selectedTabIndex: 2, tabPaneIDs: [["a", "b"], ["c", "d"]]),
            post: .init(selectedTabIndex: 1, tabPaneIDs: [["a", "b", "c", "d"]]),
            keyIsBinding: true,
            performKeyEquivalentHandled: false
        )

        #expect(!report.passed)
    }
}
