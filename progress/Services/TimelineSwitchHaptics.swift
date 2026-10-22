import Foundation
import UIKit

@MainActor
final class TimelineSwitchHaptics {
    private let playback: any TimelineSwitchHapticPlayback
    private let isActive: @MainActor () -> Bool
    private let fallback: (@MainActor () -> Void)?
    private lazy var heavy = UIImpactFeedbackGenerator(style: .heavy)

    init(playback: any TimelineSwitchHapticPlayback = TimelineSwitchHapticPlayer(),
         isActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
         fallback: (@MainActor () -> Void)? = nil) {
        self.playback = playback
        self.isActive = isActive
        self.fallback = fallback
    }

    isolated deinit { playback.stop() }

    func prepare() {
        guard isActive() else { return }
        if fallback == nil { heavy.prepare() }
        try? playback.prepare()
    }

    func play() {
        guard isActive() else { cancel(); return }
        // Fast switching replaces the previous pattern instead of layering it.
        playback.stopPlayback()
        do { try playback.play() }
        catch {
            playback.stop()
            if let fallback { fallback() }
            else { heavy.impactOccurred(intensity: 1) }
        }
    }

    func cancel() { playback.stop() }
}
