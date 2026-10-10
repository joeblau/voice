import XCTest

/// The rendered SwiftUI text bounds, independent of UIKit's selectable-text
/// accessibility frame (which can omit margins on iOS 27).
@MainActor
enum ChatGeometry {
    static func frames(for identifier: String, in app: XCUIApplication) -> [CGRect] {
        let query = app.descendants(matching: .any).matching(identifier: "\(identifier).geometry")
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 10), "No geometry for \(identifier)")
        return query.allElementsBoundByIndex.compactMap { element in
            guard element.exists else { return nil }
            let values = (element.value as? String ?? "").split(separator: ",").compactMap { Double($0) }
            guard values.count == 4 else {
                XCTFail("Malformed row geometry: \(String(describing: element.value))")
                return nil
            }
            let frame = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
            return frame.isEmpty ? nil : frame
        }
    }
}
