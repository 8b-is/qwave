import Testing
@testable import BrowserCore

@MainActor
@Test func tabManagerSelectionPersistsAfterSuspension() async {
    let manager = TabManager()
    let first = Tab()
    let second = Tab()
    manager.append(first)
    manager.append(second)

    await Task.yield()

    #expect(manager.selectedTabID == second.id)
    #expect(manager.tabs.map(\.id) == [first.id, second.id])
}
