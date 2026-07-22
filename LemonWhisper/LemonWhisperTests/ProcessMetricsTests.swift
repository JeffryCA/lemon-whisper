import Darwin
import XCTest
@testable import LemonWhisper

final class ProcessMetricsTests: XCTestCase {
    func testAdditionalProcessFootprintIsIncludedInDisplayedTotal() {
        let mainProcessOnly = currentProcessMemoryMB()
        let mainProcessCountedAgainAsAChild = currentProcessMemoryMB(including: [getpid()])

        XCTAssertGreaterThan(mainProcessCountedAgainAsAChild, mainProcessOnly)
    }
}
