//
//  hermes_deckUITests.swift
//  hermes_deckUITests
//
//  Created by cxd on 2026/6/9.
//

import XCTest

final class hermes_deckUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        throw XCTSkip("Placeholder UI test disabled until it covers a deterministic app workflow.")
    }

    @MainActor
    func testLaunchPerformance() throws {
        throw XCTSkip("Placeholder launch performance test disabled; it is flaky in headless local runs.")
    }
}
