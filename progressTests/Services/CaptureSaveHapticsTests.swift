import Foundation
import Testing
@testable import progress

@MainActor
struct CaptureSaveHapticsTests {
    @Test("Saving pulses stop before flight; takeoff and landing occur once", .timeLimit(.minutes(1)))
    func successfulSaveFollowsAnimationEvents() async throws {
        let clock = ManualHapticClock()
        defer { clock.finish() }
        var cues: [CaptureSaveHaptics.Cue] = []
        let feedback = CaptureSaveHaptics(now: { clock.time }, wait: { await clock.wait($0) }, onCue: { cues.append($0) })
        let pulses = feedback.beginSaving()
        #expect(cues == [.savePressed])
        feedback.beginFlight()
        feedback.land()
        #expect(cues == [.savePressed], "Unsaved photos must never receive success feedback.")

        var waits = clock.waits.makeAsyncIterator()
        try #require(await waits.next() != nil)
        clock.advance(by: 0.15)
        try #require(await waits.next() != nil)
        #expect(cues == [.savePressed, .savingPulse])
        feedback.didSave()
        clock.advance(by: 0.15)
        await pulses.value
        #expect(cues == [.savePressed, .savingPulse])
        feedback.beginFlight()
        feedback.beginFlight()
        feedback.land()
        feedback.land()
        #expect(cues == [.savePressed, .savingPulse, .takeoff, .landing])
    }

    @Test("Save feedback stops by 1.5 seconds even when the task wakes late", .timeLimit(.minutes(1)))
    func slowSaveHasBoundedPulses() async throws {
        let clock = ManualHapticClock()
        defer { clock.finish() }
        var cues: [CaptureSaveHaptics.Cue] = []
        let feedback = CaptureSaveHaptics(now: { clock.time }, wait: { await clock.wait($0) }, onCue: { cues.append($0) })
        let pulses = feedback.beginSaving()
        var waits = clock.waits.makeAsyncIterator()
        try #require(await waits.next() != nil)
        for _ in 0..<4 {
            clock.advance(by: 0.15)
            try #require(await waits.next() != nil)
        }
        clock.advance(by: 1)
        await pulses.value
        #expect(cues == [.savePressed] + Array(repeating: .savingPulse, count: 4))
        #expect(clock.requestedDelays.allSatisfy { $0 == .milliseconds(150) })
        // Reaching the pulse limit must not suppress the eventual success cues.
        feedback.didSave()
        feedback.beginFlight()
        feedback.land()
        #expect(Array(cues.suffix(2)) == [.takeoff, .landing])
    }

    @Test("Failure or leaving the camera cancels delayed feedback; retry starts fresh", .timeLimit(.minutes(1)))
    func cancellationAndRetryDoNotLeakCues() async throws {
        let clock = ManualHapticClock()
        defer { clock.finish() }
        var cues: [CaptureSaveHaptics.Cue] = []
        let feedback = CaptureSaveHaptics(now: { clock.time }, wait: { await clock.wait($0) }, onCue: { cues.append($0) })
        let first = feedback.beginSaving()
        var waits = clock.waits.makeAsyncIterator()
        try #require(await waits.next() != nil)
        feedback.cancel()
        feedback.didSave()
        feedback.beginFlight()
        feedback.land()
        clock.advance(by: 0.15)
        await first.value
        #expect(cues == [.savePressed])

        let retry = feedback.beginSaving()
        try #require(await waits.next() != nil)
        feedback.didSave()
        clock.advance(by: 0.15)
        await retry.value
        feedback.beginFlight()
        feedback.land()
        #expect(cues == [.savePressed, .savePressed, .takeoff, .landing])
    }
}

@MainActor
private final class ManualHapticClock {
    var time: TimeInterval = 0
    private(set) var requestedDelays: [Duration] = []
    let waits: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var sleepers: [CheckedContinuation<Void, Never>] = []

    init() {
        (waits, continuation) = AsyncStream<Void>.makeStream()
    }

    func wait(_ delay: Duration) async {
        requestedDelays.append(delay)
        await withCheckedContinuation { sleeper in
            sleepers.append(sleeper)
            continuation.yield(())
        }
    }

    func advance(by elapsed: TimeInterval) {
        time += elapsed
        if !sleepers.isEmpty { sleepers.removeFirst().resume() }
    }

    func finish() {
        for sleeper in sleepers { sleeper.resume() }
        sleepers.removeAll()
        continuation.finish()
    }
}
