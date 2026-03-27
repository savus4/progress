import Foundation
import Combine

@MainActor
final class AlignmentGuideStore: ObservableObject {
    static let shared = AlignmentGuideStore()

    @Published var eyeLinePosition: Double {
        didSet {
            persistGuideIfNeeded()
        }
    }

    @Published var mouthLinePosition: Double {
        didSet {
            persistGuideIfNeeded()
        }
    }

    private let localDefaults: UserDefaults
    private let ubiquitousStore: NSUbiquitousKeyValueStore
    private let guideStorageKey = "alignmentGuide"
    private var isApplyingExternalChange = false
    private var ubiquitousChangeObserver: NSObjectProtocol?

    private init(
        localDefaults: UserDefaults = .standard,
        ubiquitousStore: NSUbiquitousKeyValueStore = .default
    ) {
        self.localDefaults = localDefaults
        self.ubiquitousStore = ubiquitousStore

        let initialGuide = Self.loadInitialGuide(
            localDefaults: localDefaults,
            ubiquitousStore: ubiquitousStore
        )
        eyeLinePosition = initialGuide.eyeLinePosition
        mouthLinePosition = initialGuide.mouthLinePosition

        ubiquitousChangeObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: ubiquitousStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyGuideFromUbiquitousStore()
            }
        }

        ubiquitousStore.synchronize()
        persistGuide()
    }

    deinit {
        if let ubiquitousChangeObserver {
            NotificationCenter.default.removeObserver(ubiquitousChangeObserver)
        }
    }

    private static func loadInitialGuide(
        localDefaults: UserDefaults,
        ubiquitousStore: NSUbiquitousKeyValueStore
    ) -> AlignmentGuide {
        if let ubiquitousData = ubiquitousStore.data(forKey: "alignmentGuide"),
           let guide = try? JSONDecoder().decode(AlignmentGuide.self, from: ubiquitousData) {
            return guide
        }

        if let localData = localDefaults.data(forKey: "alignmentGuide"),
           let guide = try? JSONDecoder().decode(AlignmentGuide.self, from: localData) {
            return guide
        }

        let legacyEyeLinePosition = localDefaults.object(forKey: "eyeLinePosition") as? Double
        let legacyMouthLinePosition = localDefaults.object(forKey: "mouthLinePosition") as? Double
        if let legacyEyeLinePosition, let legacyMouthLinePosition {
            return AlignmentGuide(
                eyeLinePosition: legacyEyeLinePosition,
                mouthLinePosition: legacyMouthLinePosition
            )
        }

        return .default
    }

    private func applyGuideFromUbiquitousStore() {
        guard let guideData = ubiquitousStore.data(forKey: guideStorageKey),
              let guide = try? JSONDecoder().decode(AlignmentGuide.self, from: guideData) else {
            return
        }

        isApplyingExternalChange = true
        eyeLinePosition = guide.eyeLinePosition
        mouthLinePosition = guide.mouthLinePosition
        isApplyingExternalChange = false

        persistGuide()
    }

    private func persistGuideIfNeeded() {
        guard !isApplyingExternalChange else { return }
        persistGuide()
    }

    private func persistGuide() {
        let guide = AlignmentGuide(
            eyeLinePosition: eyeLinePosition,
            mouthLinePosition: mouthLinePosition
        )

        guard let guideData = try? JSONEncoder().encode(guide) else { return }

        localDefaults.set(guideData, forKey: guideStorageKey)
        localDefaults.set(eyeLinePosition, forKey: "eyeLinePosition")
        localDefaults.set(mouthLinePosition, forKey: "mouthLinePosition")

        ubiquitousStore.set(guideData, forKey: guideStorageKey)
    }
}
