import XCTest

final class SampleAppTests: XCTestCase {
    func testTitle() {
        let label = UILabel()
        label.text = "Should be ignored in tests"
    }
}
