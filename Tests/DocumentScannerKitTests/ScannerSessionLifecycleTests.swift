import XCTest
@testable import DocumentScannerKit

final class ScannerSessionLifecycleTests: XCTestCase {

    func testAppearanceBeforeConfigurationDoesNotStartTheSession() {
        var lifecycle = ScannerSessionLifecycle()

        lifecycle.requestStart()

        XCTAssertFalse(lifecycle.shouldStart)

        lifecycle.markConfigured()

        XCTAssertTrue(lifecycle.shouldStart)
    }

    func testConfigurationBeforeAppearanceWaitsForTheScannerToAppear() {
        var lifecycle = ScannerSessionLifecycle()

        lifecycle.markConfigured()

        XCTAssertFalse(lifecycle.shouldStart)

        lifecycle.requestStart()

        XCTAssertTrue(lifecycle.shouldStart)
    }

    func testRepeatedConfigurationLeavesTheLifecycleReadyToStart() {
        var lifecycle = ScannerSessionLifecycle()

        lifecycle.requestStart()
        lifecycle.markConfigured()
        lifecycle.markConfigured()

        XCTAssertTrue(lifecycle.isConfigured)
        XCTAssertTrue(lifecycle.shouldStart)
    }

    func testDisappearanceBeforeConfigurationPreventsDeferredStartup() {
        var lifecycle = ScannerSessionLifecycle()

        lifecycle.requestStart()
        lifecycle.requestStop()
        lifecycle.markConfigured()

        XCTAssertFalse(lifecycle.shouldStart)
    }

    func testReappearingRequestsStartAfterTheSessionWasStopped() {
        var lifecycle = ScannerSessionLifecycle()

        lifecycle.markConfigured()
        lifecycle.requestStart()
        lifecycle.requestStop()

        XCTAssertFalse(lifecycle.shouldStart)

        lifecycle.requestStart()

        XCTAssertTrue(lifecycle.shouldStart)
    }
}
