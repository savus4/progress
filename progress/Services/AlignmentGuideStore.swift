import Foundation
import Combine

protocol AlignmentGuideCloudStorage: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: AlignmentGuideCloudStorage {}

@MainActor
final class AlignmentGuideStore: ObservableObject {
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
    private let ubiquitousStore: (any AlignmentGuideCloudStorage)?
    private let storageModeStore: PhotoStorageModeStore
    private let timelineID: UUID
    private let guideStorageKey: String
    private var isApplyingExternalChange = false
    private var ubiquitousChangeObserver: NSObjectProtocol?
    private var storageModeObserver: NSObjectProtocol?
    private var pendingSyncKey: String { guideStorageKey + ".pendingSync" }
    private var allowsCloud: Bool { Self.allowsCloud(storageModeStore) }

    init(
        timelineID: UUID = TimelineIdentity.defaultID,
        localDefaults: UserDefaults = .standard,
        ubiquitousStore: (any AlignmentGuideCloudStorage)? = NSUbiquitousKeyValueStore.default,
        storageModeStore: PhotoStorageModeStore = .shared
    ) {
        self.timelineID = timelineID
        self.localDefaults = localDefaults
        self.ubiquitousStore = ubiquitousStore
        self.storageModeStore = storageModeStore
        guideStorageKey = Self.storageKey(for: timelineID)

        let initialGuide = Self.loadInitialGuide(
            timelineID: timelineID,
            localDefaults: localDefaults,
            ubiquitousStore: Self.allowsCloud(storageModeStore) && !localDefaults.bool(forKey: guideStorageKey + ".pendingSync") ? ubiquitousStore : nil
        )
        eyeLinePosition = initialGuide.eyeLinePosition
        mouthLinePosition = initialGuide.mouthLinePosition

        if let ubiquitousStore {
            ubiquitousChangeObserver = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: ubiquitousStore,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applyGuideFromUbiquitousStore()
                }
            }
            if allowsCloud { ubiquitousStore.synchronize() }
        }
        // Do not upload a fresh default before the cloud store has imported its
        // existing guide. Actual edits publish to this timeline's own cloud key.
        persistGuide(publishesToCloud: false)
        storageModeObserver = NotificationCenter.default.addObserver(
            forName: PhotoStorageModeStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronizeStorageMode() }
        }
        synchronizeStorageMode()
    }

    isolated deinit {
        if let storageModeObserver { NotificationCenter.default.removeObserver(storageModeObserver) }
        if let ubiquitousChangeObserver {
            NotificationCenter.default.removeObserver(ubiquitousChangeObserver)
        }
    }

    static func storageKey(for timelineID: UUID) -> String {
        // The original timeline retains both the local and iCloud legacy keys.
        timelineID == TimelineIdentity.defaultID ? "alignmentGuide" : "alignmentGuide.\(timelineID.uuidString)"
    }

    private static func allowsCloud(_ store: PhotoStorageModeStore) -> Bool {
        guard store.mode.allowsCloudWrites else { return false }
        #if DEBUG && targetEnvironment(simulator)
        if store === PhotoStorageModeStore.shared, SimulatorExampleLibrary.isEnabled { return false }
        #endif
        return true
    }

    static func removeSettings(for timelineID: UUID, localDefaults: UserDefaults = .standard,
                               ubiquitousStore: (any AlignmentGuideCloudStorage)? = NSUbiquitousKeyValueStore.default,
                               storageModeStore: PhotoStorageModeStore = .shared, syncsDeletion: Bool = true) {
        let key = storageKey(for: timelineID)
        localDefaults.removeObject(forKey: key)
        localDefaults.removeObject(forKey: key + ".pendingSync")
        if syncsDeletion, allowsCloud(storageModeStore), ubiquitousStore?.data(forKey: key) != nil {
            ubiquitousStore?.removeObject(forKey: key)
        }
        if timelineID == TimelineIdentity.defaultID {
            localDefaults.removeObject(forKey: "eyeLinePosition")
            localDefaults.removeObject(forKey: "mouthLinePosition")
        }
    }

    /// Local edits survive relaunch and publish only after this device opts in.
    func synchronizeStorageMode() {
        guard allowsCloud else { return }
        if localDefaults.bool(forKey: pendingSyncKey) { persistGuide() }
        else { applyGuideFromUbiquitousStore() }
        ubiquitousStore?.synchronize()
    }

    private static func loadInitialGuide(
        timelineID: UUID,
        localDefaults: UserDefaults,
        ubiquitousStore: (any AlignmentGuideCloudStorage)?
    ) -> AlignmentGuide {
        let key = storageKey(for: timelineID)
        if let ubiquitousData = ubiquitousStore?.data(forKey: key),
           let guide = try? JSONDecoder().decode(AlignmentGuide.self, from: ubiquitousData) {
            return guide
        }

        if let localData = localDefaults.data(forKey: key),
           let guide = try? JSONDecoder().decode(AlignmentGuide.self, from: localData) {
            return guide
        }

        if timelineID == TimelineIdentity.defaultID,
           let legacyEyeLinePosition = localDefaults.object(forKey: "eyeLinePosition") as? Double,
           let legacyMouthLinePosition = localDefaults.object(forKey: "mouthLinePosition") as? Double {
            return AlignmentGuide(
                eyeLinePosition: legacyEyeLinePosition,
                mouthLinePosition: legacyMouthLinePosition
            )
        }

        return .default
    }

    private func applyGuideFromUbiquitousStore() {
        guard allowsCloud, !localDefaults.bool(forKey: pendingSyncKey) else { return }
        guard let guideData = ubiquitousStore?.data(forKey: guideStorageKey),
              let guide = try? JSONDecoder().decode(AlignmentGuide.self, from: guideData) else {
            return
        }

        isApplyingExternalChange = true
        eyeLinePosition = guide.eyeLinePosition
        mouthLinePosition = guide.mouthLinePosition
        isApplyingExternalChange = false

        persistGuide(publishesToCloud: false)
    }

    private func persistGuideIfNeeded() {
        guard !isApplyingExternalChange else { return }
        persistGuide()
    }

    private func persistGuide(publishesToCloud: Bool = true) {
        let guide = AlignmentGuide(
            eyeLinePosition: eyeLinePosition,
            mouthLinePosition: mouthLinePosition
        )

        guard let guideData = try? JSONEncoder().encode(guide) else { return }

        localDefaults.set(guideData, forKey: guideStorageKey)
        if timelineID == TimelineIdentity.defaultID {
            localDefaults.set(eyeLinePosition, forKey: "eyeLinePosition")
            localDefaults.set(mouthLinePosition, forKey: "mouthLinePosition")
        }

        if publishesToCloud {
            if allowsCloud, let ubiquitousStore {
                ubiquitousStore.set(guideData, forKey: guideStorageKey)
                localDefaults.removeObject(forKey: pendingSyncKey)
            } else {
                localDefaults.set(true, forKey: pendingSyncKey)
            }
        }
    }
}
