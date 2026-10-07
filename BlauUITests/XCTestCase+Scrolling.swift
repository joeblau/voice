import XCTest

extension XCTestCase {
    /// Swipes `container` up until `element` exists and is hittable.
    ///
    /// SwiftUI `Form`s and `List`s are lazy: a row below the fold isn't in
    /// the accessibility tree until it has been scrolled into view, so
    /// `waitForExistence` alone never finds it. Settings grows a section with
    /// most features, so any test that opens a Settings row scrolls first.
    @MainActor
    func scrollTo(
        _ element: XCUIElement,
        in container: XCUIElement,
        maxSwipes: Int = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            container.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(element.waitForExistence(timeout: 2), "\(element) not found", file: file, line: line)
    }
}
