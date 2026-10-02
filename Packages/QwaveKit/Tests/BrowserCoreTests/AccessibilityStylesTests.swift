import XCTest
import Persistence
@testable import BrowserCore

final class AccessibilityStylesTests: XCTestCase {
    func testSystemThemeInjectsNothing() {
        XCTAssertNil(AccessibilityStyles.colorSchemeScript(for: .system))
    }

    func testForcedDarkInjectsDarkColorScheme() {
        let script = try! XCTUnwrap(AccessibilityStyles.colorSchemeScript(for: .dark))
        XCTAssertTrue(script.contains("color-scheme"))
        XCTAssertTrue(script.contains("'dark'"))
        XCTAssertTrue(script.contains(":root { color-scheme: dark; }"))
    }

    func testForcedLightInjectsLightColorScheme() {
        let script = try! XCTUnwrap(AccessibilityStyles.colorSchemeScript(for: .light))
        XCTAssertTrue(script.contains("'light'"))
        XCTAssertTrue(script.contains(":root { color-scheme: light; }"))
    }

    func testReduceMotionScriptCollapsesCSSMotion() {
        let script = AccessibilityStyles.reduceMotionScript
        XCTAssertTrue(script.contains("animation-duration: 0.001s !important"))
        XCTAssertTrue(script.contains("transition-duration: 0.001s !important"))
        XCTAssertTrue(script.contains("animation-iteration-count: 1 !important"))
        XCTAssertTrue(script.contains("scroll-behavior: auto !important"))
    }
}
