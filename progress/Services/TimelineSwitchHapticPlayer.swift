import CoreHaptics
import Foundation

@MainActor
protocol TimelineSwitchHapticPlayback: AnyObject {
    func prepare() throws
    func play() throws
    func stopPlayback()
    func stop()
}

/// Owns the engine and one player; interruptions never replay an old switch.
@MainActor
final class TimelineSwitchHapticPlayer: TimelineSwitchHapticPlayback {
    private enum PlaybackError: Error { case unsupported }

    private var engine: CHHapticEngine?
    private var player: (any CHHapticPatternPlayer)?
    private var pattern: CHHapticPattern?
    private var engineID: UUID?

    isolated deinit {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        engine?.stop(completionHandler: nil)
    }

    func prepare() throws {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { throw PlaybackError.unsupported }
        if pattern == nil { pattern = try Self.makePattern() }
        if engine == nil {
            let newEngine = try CHHapticEngine()
            newEngine.playsHapticsOnly = true
            newEngine.isAutoShutdownEnabled = true
            let id = UUID()
            engineID = id
            newEngine.resetHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    // A late reset from a retired engine must not cancel a new one.
                    guard self?.engineID == id else { return }
                    self?.stop()
                }
            }
            engine = newEngine
        }
        // Restart after idle shutdown or audio interruption, only on user demand.
        try engine?.start()
    }

    func play() throws {
        try prepare()
        guard let engine, let pattern else { throw PlaybackError.unsupported }
        let newPlayer = try engine.makePlayer(with: pattern)
        player = newPlayer
        try newPlayer.start(atTime: CHHapticTimeImmediate)
    }

    func stopPlayback() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
    }

    func stop() {
        stopPlayback()
        let oldEngine = engine
        engine = nil
        engineID = nil
        oldEngine?.stop(completionHandler: nil)
    }

    static func makePattern() throws -> CHHapticPattern {
        let snap = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.95)
        ], relativeTime: 0)
        let pull = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25)
        ], relativeTime: 0.015, duration: 0.095)
        let landing = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
        ], relativeTime: 0.125)
        let settle = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.24),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1)
        ], relativeTime: 0.185)
        let pullIntensity = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
            .init(relativeTime: 0, value: 0.25),
            .init(relativeTime: 0.045, value: 0.75),
            // Dynamic controls affect future events too: restore full strength
            // before the landing so the pull cannot attenuate the final impact.
            .init(relativeTime: 0.095, value: 1)
        ], relativeTime: 0.015)
        return try CHHapticPattern(events: [snap, pull, landing, settle], parameterCurves: [pullIntensity])
    }
}
