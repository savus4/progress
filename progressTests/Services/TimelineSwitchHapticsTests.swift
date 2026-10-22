import CoreHaptics
import Foundation
import Testing
@testable import progress

@MainActor
struct TimelineSwitchHapticsTests {
    @Test("Rapid switches replace playback instead of overlapping")
    func rapidSwitchesStayDistinct() {
        let player = Player()
        var fallbacks = 0
        let feedback = TimelineSwitchHaptics(playback: player, isActive: { true }, fallback: { fallbacks += 1 })
        feedback.prepare()
        #expect(player.plays == 0, "Preparing Settings must never emit a haptic.")
        for _ in 0..<5 { feedback.play() }
        #expect(player.plays == 5)
        #expect(player.maxActivePlayers == 1)
        #expect(fallbacks == 0)
    }

    @Test("An unavailable engine falls back once, and a later switch can recover")
    func failureDoesNotSuppressFutureSwitches() {
        let player = Player()
        player.fails = true
        var fallbacks = 0
        let feedback = TimelineSwitchHaptics(playback: player, isActive: { true }, fallback: { fallbacks += 1 })
        feedback.prepare()
        #expect(fallbacks == 0)
        feedback.play()
        #expect(fallbacks == 1)
        #expect(player.activePlayers == 0)
        player.fails = false
        feedback.play()
        #expect(player.activePlayers == 1)
        #expect(fallbacks == 1)
    }

    @Test("Backgrounding or leaving Settings stops playback, with no replay on return")
    func leavingStopsAllFeedback() {
        let player = Player()
        var fallbacks = 0
        let feedback = TimelineSwitchHaptics(playback: player, isActive: { player.appIsActive }, fallback: { fallbacks += 1 })
        feedback.play()
        #expect(player.activePlayers == 1)
        player.appIsActive = false
        feedback.play()
        feedback.prepare()
        #expect(player.activePlayers == 0)
        #expect(player.plays == 1)
        #expect(fallbacks == 0)
        player.appIsActive = true
        feedback.prepare()
        #expect(player.plays == 1)
        feedback.play()
        feedback.cancel()
        #expect(player.activePlayers == 0)
    }

    @Test("Core Haptics accepts the pattern, which finishes within the switch animation")
    func patternIsValidAndBrief() throws {
        let pattern = try TimelineSwitchHapticPlayer.makePattern()
        #expect(pattern.duration > 0)
        #expect(pattern.duration <= 0.22)
    }

    private final class Player: TimelineSwitchHapticPlayback {
        enum Failure: Error { case unavailable }
        var appIsActive = true
        var fails = false
        var plays = 0
        var activePlayers = 0
        var maxActivePlayers = 0
        func prepare() throws { if fails { throw Failure.unavailable } }
        func play() throws {
            activePlayers += 1
            maxActivePlayers = max(maxActivePlayers, activePlayers)
            if fails { throw Failure.unavailable }
            plays += 1
        }
        func stopPlayback() { activePlayers = 0 }
        func stop() { stopPlayback() }
    }
}
