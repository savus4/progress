import Foundation
import UIKit

/// Coordinates tactile feedback with saving and the preview's actual animation.
@MainActor
final class CaptureSaveHaptics {
    nonisolated enum Cue: Equatable, Sendable {
        case savePressed
        case savingPulse
        case takeoff
        case landing
    }

    private enum Phase { case idle, saving, readyToFly, flying }
    private var phase = Phase.idle
    private var pulseTask: Task<Void, Never>?
    private let now: @MainActor () -> TimeInterval
    private let wait: @MainActor (Duration) async throws -> Void
    private let onCue: (@MainActor (Cue) -> Void)?
    private lazy var soft = UIImpactFeedbackGenerator(style: .soft)
    private lazy var medium = UIImpactFeedbackGenerator(style: .medium)
    private lazy var heavy = UIImpactFeedbackGenerator(style: .heavy)

    init(now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         onCue: (@MainActor (Cue) -> Void)? = nil) {
        self.now = now
        self.wait = wait
        self.onCue = onCue
    }

    isolated deinit { pulseTask?.cancel() }

    func prepare() {
        guard onCue == nil, UIApplication.shared.applicationState == .active else { return }
        soft.prepare()
    }

    @discardableResult
    func beginSaving() -> Task<Void, Never> {
        cancel()
        phase = .saving
        prepare()
        emit(.savePressed)
        let deadline = now() + 1.5
        let wait = wait
        let now = now
        let task = Task { [weak self] in
            for _ in 0..<9 {
                do { try await wait(.milliseconds(150)) }
                catch { return }
                guard !Task.isCancelled, now() < deadline, self?.phase == .saving else { return }
                self?.emit(.savingPulse)
            }
        }
        pulseTask = task
        return task
    }

    func didSave() {
        guard phase == .saving else { return }
        pulseTask?.cancel()
        pulseTask = nil
        phase = .readyToFly
    }

    func beginFlight() {
        guard phase == .readyToFly else { return }
        phase = .flying
        emit(.takeoff)
    }

    func land() {
        guard phase == .flying else { return }
        phase = .idle
        emit(.landing)
    }

    func cancel() {
        pulseTask?.cancel()
        pulseTask = nil
        phase = .idle
    }

    private func emit(_ cue: Cue) {
        if let onCue { onCue(cue); return }
        guard UIApplication.shared.applicationState == .active else { return }
        switch cue {
        case .savePressed:
            soft.impactOccurred(intensity: 0.65)
            soft.prepare()
        case .savingPulse:
            soft.impactOccurred(intensity: 0.3)
            soft.prepare()
        case .takeoff:
            medium.prepare()
            medium.impactOccurred(intensity: 0.85)
            heavy.prepare()
        case .landing:
            heavy.impactOccurred(intensity: 1)
        }
    }
}
