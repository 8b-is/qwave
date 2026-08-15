import XCTest
@testable import BrowserCore

final class SpacesLayoutTests: XCTestCase {
    func testSpacesLeadsWithDefaultThenPersistentProfiles() {
        let work = ContainerProfile(name: "Work", colorHex: "#4A90D9")
        let personal = ContainerProfile(name: "Personal", colorHex: "#50B860")
        let spaces = SpacesLayout.spaces(from: [work, personal])
        XCTAssertEqual(spaces.map(\.id), [nil, work.id, personal.id])
        XCTAssertEqual(spaces.first?.name, "Default")
    }

    func testSpacesExcludesEphemeralProfiles() {
        let burner = ContainerProfile(name: "Burner", colorHex: "#9B59B6", isEphemeral: true)
        let work = ContainerProfile(name: "Work", colorHex: "#4A90D9")
        let spaces = SpacesLayout.spaces(from: [burner, work])
        XCTAssertEqual(spaces.map(\.id), [nil, work.id])
    }

    func testTabIDsGroupsByContainerAndSkipsEphemeral() {
        let work = UUID()
        let placements = [
            TabPlacement(id: UUID(), containerID: nil, isEphemeral: false),   // default
            TabPlacement(id: UUID(), containerID: work, isEphemeral: false),  // work
            TabPlacement(id: UUID(), containerID: work, isEphemeral: false),  // work
            TabPlacement(id: UUID(), containerID: nil, isEphemeral: true),    // burner, never grouped
        ]
        XCTAssertEqual(SpacesLayout.tabIDs(inSpace: nil, tabs: placements), [placements[0].id])
        XCTAssertEqual(SpacesLayout.tabIDs(inSpace: work, tabs: placements), [placements[1].id, placements[2].id])
    }

    func testFirstTabIDReturnsNilForEmptySpace() {
        let work = UUID()
        let placements = [TabPlacement(id: UUID(), containerID: nil, isEphemeral: false)]
        XCTAssertNil(SpacesLayout.firstTabID(inSpace: work, tabs: placements))
        XCTAssertEqual(SpacesLayout.firstTabID(inSpace: nil, tabs: placements), placements[0].id)
    }
}
