import Testing
import UIKit
@testable import progress

@MainActor
struct PhotoDetailOpeningReadinessTests {
    @Test("Opening waits for appearance, then keeps the source frame for a display interval")
    func waitsForAppearanceAndTwoDisplayFrames() throws {
        let controller = PhotoDetailOpeningReadinessView.Controller()
        let window = try makeWindow()
        window.addSubview(controller.view)
        controller.view.frame = window.bounds
        var readyCount = 0
        controller.onReady = { readyCount += 1 }
        defer { withExtendedLifetime(window) { controller.cancel() } }

        controller.viewDidLayoutSubviews()
        controller.displayFrame()
        controller.displayFrame()
        #expect(readyCount == 0)

        controller.viewDidAppear(false)
        controller.displayFrame()
        #expect(readyCount == 0)
        controller.displayFrame()
        #expect(readyCount == 1)

        controller.displayFrame()
        controller.displayFrame()
        #expect(readyCount == 1)
    }

    @Test("Opening waits for a window and nonzero layout before observing frames")
    func waitsForWindowAndLayout() throws {
        let controller = PhotoDetailOpeningReadinessView.Controller()
        var readyCount = 0
        controller.onReady = { readyCount += 1 }

        controller.loadViewIfNeeded()
        controller.viewDidAppear(false)
        controller.displayFrame()
        controller.displayFrame()
        #expect(readyCount == 0)

        let window = try makeWindow()
        defer { withExtendedLifetime(window) { controller.cancel() } }
        controller.view.frame = .zero
        window.addSubview(controller.view)
        controller.viewDidLayoutSubviews()
        controller.displayFrame()
        controller.displayFrame()
        #expect(readyCount == 0)

        controller.view.frame = window.bounds
        controller.viewDidLayoutSubviews()
        controller.displayFrame()
        #expect(readyCount == 0)
        controller.displayFrame()
        #expect(readyCount == 1)
    }

    @Test("Disappearing restarts the initial frame wait and readiness is delivered only once")
    func reappearanceRestartsFrameWait() throws {
        let controller = PhotoDetailOpeningReadinessView.Controller()
        let window = try makeWindow()
        window.addSubview(controller.view)
        controller.view.frame = window.bounds
        var readyCount = 0
        controller.onReady = { readyCount += 1 }
        defer { withExtendedLifetime(window) { controller.cancel() } }

        controller.viewDidAppear(false)
        controller.displayFrame()
        controller.viewWillDisappear(false)
        controller.displayFrame()
        #expect(readyCount == 0)

        controller.viewDidAppear(false)
        controller.displayFrame()
        #expect(readyCount == 0)
        controller.displayFrame()
        #expect(readyCount == 1)

        controller.viewWillDisappear(false)
        controller.viewDidAppear(false)
        controller.onReady = { readyCount += 1 }
        controller.displayFrame()
        controller.displayFrame()
        #expect(readyCount == 1)
    }

    @Test("Dismantling cancels pending readiness even if appearance callbacks arrive later")
    func cancellationPreventsReadiness() throws {
        let controller = PhotoDetailOpeningReadinessView.Controller()
        let window = try makeWindow()
        defer { withExtendedLifetime(window) { controller.cancel() } }
        window.addSubview(controller.view)
        controller.view.frame = window.bounds
        var readyCount = 0
        controller.onReady = { readyCount += 1 }

        controller.viewDidAppear(false)
        controller.displayFrame()
        PhotoDetailOpeningReadinessView.dismantleUIViewController(controller, coordinator: ())
        controller.displayFrame()
        #expect(readyCount == 0)

        controller.viewWillDisappear(false)
        controller.onReady = { readyCount += 1 }
        controller.viewDidAppear(false)
        controller.viewDidLayoutSubviews()
        controller.displayFrame()
        controller.displayFrame()
        #expect(readyCount == 0)
    }

    private func makeWindow() throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        return window
    }
}
