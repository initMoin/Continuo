//
//  ContinuoUITests.swift
//  ContinuoUITests
//
//  Created by Moinuddin Ahmad on 8/14/26.
//

import XCTest
import Foundation

final class ContinuoUITests: XCTestCase {

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
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    func testCaptureAppStoreViews() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--capture-app-store-views"]
        app.launch()
        dismissOnboardingIfNeeded(in: app)

        capture("01-workflow", screen: XCUIScreen.main)

        let moreOptions = app.buttons["More options"]
        XCTAssertTrue(moreOptions.waitForExistence(timeout: 8), "More options must be available for screenshot capture.")
        let moreOptionsHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: moreOptions
        )
        XCTAssertEqual(XCTWaiter.wait(for: [moreOptionsHittable], timeout: 5), .completed)
        moreOptions.tap()
        capture("02-more-options", screen: XCUIScreen.main)

        moreOptions.tap()
        let intelligence = app.buttons["Intelligence"]
        XCTAssertTrue(intelligence.waitForExistence(timeout: 5), "Intelligence must be available in the menu.")
        intelligence.tap()
        XCTAssertTrue(app.navigationBars["Intelligence"].waitForExistence(timeout: 5), "Intelligence must open.")
        capture("03-intelligence", screen: XCUIScreen.main)
        dismissSheet(in: app)

        moreOptions.tap()
        let about = app.buttons["About Continuo"]
        XCTAssertTrue(about.waitForExistence(timeout: 5), "About Continuo must be available in the menu.")
        about.tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5), "About must open.")
        capture("04-about", screen: XCUIScreen.main)

        let support = app.buttons["Support Continuo"]
        XCTAssertTrue(support.waitForExistence(timeout: 5), "Support Continuo must be available in About.")
        support.tap()
        capture("05-support", screen: XCUIScreen.main)
    }

    @MainActor
    private func dismissOnboardingIfNeeded(in app: XCUIApplication) {
        let next = app.buttons["Next onboarding page"]
        guard next.waitForExistence(timeout: 2) else { return }

        next.tap()
        XCTAssertTrue(next.waitForExistence(timeout: 2))
        next.tap()

        let finish = app.buttons["Finish onboarding"]
        XCTAssertTrue(finish.waitForExistence(timeout: 2))
        finish.tap()

        let onboardingDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: finish
        )
        _ = XCTWaiter.wait(for: [onboardingDismissed], timeout: 5)
    }

    @MainActor
    private func dismissSheet(in app: XCUIApplication) {
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Presented view must expose a Done button.")
        done.tap()
    }

    @MainActor
    private func capture(_ name: String, screen: XCUIScreen) {
        let attachment = XCTAttachment(screenshot: screen.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
