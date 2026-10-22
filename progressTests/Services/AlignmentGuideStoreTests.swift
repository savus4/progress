import Foundation
import Testing
@testable import progress

@MainActor
struct AlignmentGuideStoreTests {
    private final class Cloud: AlignmentGuideCloudStorage {
        var values: [String: Data] = [:]
        var writes = 0
        var removals = 0
        var synchronizations = 0
        func data(forKey key: String) -> Data? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value as? Data; writes += 1 }
        func removeObject(forKey key: String) { values.removeValue(forKey: key); removals += 1 }
        func synchronize() -> Bool { synchronizations += 1; return true }
    }

    @Test("Local guide edits ignore cloud updates, survive relaunch, and publish only after opt-in")
    func localGuidesRespectStoragePreference() throws {
        let domain = "LocalGuides-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(domain + "/mode.json")
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let mode = PhotoStorageModeStore(storageURL: url)
        try mode.set(.local)
        let cloud = Cloud()
        let key = AlignmentGuideStore.storageKey(for: TimelineIdentity.defaultID)
        cloud.values[key] = try JSONEncoder().encode(AlignmentGuide(eyeLinePosition: 0.3, mouthLinePosition: 0.6))
        let guide = AlignmentGuideStore(localDefaults: defaults, ubiquitousStore: cloud, storageModeStore: mode)
        #expect(guide.eyeLinePosition == Double(AlignmentGuide.default.eyeLinePosition))
        guide.eyeLinePosition = 0.45
        let reopened = AlignmentGuideStore(localDefaults: defaults, ubiquitousStore: cloud, storageModeStore: mode)
        #expect(reopened.eyeLinePosition == 0.45)
        reopened.synchronizeStorageMode()
        #expect(cloud.writes == 0)
        #expect(cloud.synchronizations == 0)
        try mode.set(.iCloud)
        reopened.synchronizeStorageMode()
        let synced = try JSONDecoder().decode(AlignmentGuide.self, from: #require(cloud.values[key]))
        #expect(synced.eyeLinePosition == 0.45)
        #expect(cloud.writes == 1)
        #expect(!defaults.bool(forKey: key + ".pendingSync"))
    }

    @Test("Local timeline removal preserves kept cloud guides; synced deletion removes them", arguments: [false, true])
    func guideDeletionRespectsStoragePreference(syncing: Bool) throws {
        let domain = "GuideRemoval-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(domain + "/mode.json")
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let mode = PhotoStorageModeStore(storageURL: url)
        try mode.set(syncing ? .iCloud : .local)
        let cloud = Cloud()
        let id = UUID()
        let key = AlignmentGuideStore.storageKey(for: id)
        let bytes = try JSONEncoder().encode(AlignmentGuide(eyeLinePosition: 0.3, mouthLinePosition: 0.6))
        cloud.values[key] = bytes
        defaults.set(bytes, forKey: key)
        defaults.set(true, forKey: key + ".pendingSync")
        AlignmentGuideStore.removeSettings(for: id, localDefaults: defaults, ubiquitousStore: cloud, storageModeStore: mode)
        #expect(defaults.data(forKey: key) == nil)
        #expect(!defaults.bool(forKey: key + ".pendingSync"))
        #expect(cloud.values[key] == (syncing ? nil : bytes))
        #expect(cloud.removals == (syncing ? 1 : 0))
    }

    @Test("The original timeline keeps its legacy guides while a new timeline starts fresh", arguments: [false, true])
    func legacyGuidesStayWithDefaultTimeline(usesEncodedGuide: Bool) throws {
        let domain = "AlignmentGuideMigration-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(0.42, forKey: "eyeLinePosition")
        defaults.set(0.72, forKey: "mouthLinePosition")
        if usesEncodedGuide {
            let guide = AlignmentGuide(eyeLinePosition: 0.44, mouthLinePosition: 0.74)
            defaults.set(try JSONEncoder().encode(guide), forKey: "alignmentGuide")
        }

        let original = AlignmentGuideStore(localDefaults: defaults, ubiquitousStore: nil)
        let additional = AlignmentGuideStore(timelineID: UUID(), localDefaults: defaults, ubiquitousStore: nil)

        #expect(original.eyeLinePosition == (usesEncodedGuide ? 0.44 : 0.42))
        #expect(original.mouthLinePosition == (usesEncodedGuide ? 0.74 : 0.72))
        #expect(additional.eyeLinePosition == Double(AlignmentGuide.default.eyeLinePosition))
        #expect(additional.mouthLinePosition == Double(AlignmentGuide.default.mouthLinePosition))
        let migrated = try JSONDecoder().decode(
            AlignmentGuide.self, from: #require(defaults.data(forKey: "alignmentGuide"))
        )
        #expect(Double(migrated.eyeLinePosition) == original.eyeLinePosition)
        #expect(Double(migrated.mouthLinePosition) == original.mouthLinePosition)
    }

    @Test("Editing and reopening a person's guide leaves other timelines and legacy keys unchanged")
    func guidesAreIndependentAndPersistent() throws {
        let domain = "AlignmentGuideIsolation-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let original = AlignmentGuideStore(localDefaults: defaults, ubiquitousStore: nil)
        original.eyeLinePosition = 0.41
        original.mouthLinePosition = 0.71
        let originalBytes = try #require(defaults.data(forKey: "alignmentGuide"))
        let firstID = UUID()
        let secondID = UUID()
        let first = AlignmentGuideStore(timelineID: firstID, localDefaults: defaults, ubiquitousStore: nil)
        let second = AlignmentGuideStore(timelineID: secondID, localDefaults: defaults, ubiquitousStore: nil)

        first.eyeLinePosition = 0.28
        first.mouthLinePosition = 0.58
        second.eyeLinePosition = 0.38
        second.mouthLinePosition = 0.68
        let reopenedFirst = AlignmentGuideStore(timelineID: firstID, localDefaults: defaults, ubiquitousStore: nil)
        let reopenedSecond = AlignmentGuideStore(timelineID: secondID, localDefaults: defaults, ubiquitousStore: nil)

        #expect(reopenedFirst.eyeLinePosition == 0.28)
        #expect(reopenedFirst.mouthLinePosition == 0.58)
        #expect(reopenedSecond.eyeLinePosition == 0.38)
        #expect(reopenedSecond.mouthLinePosition == 0.68)
        #expect(original.eyeLinePosition == 0.41)
        #expect(original.mouthLinePosition == 0.71)
        #expect(defaults.data(forKey: "alignmentGuide") == originalBytes)
        #expect(defaults.double(forKey: "eyeLinePosition") == 0.41)
        #expect(defaults.double(forKey: "mouthLinePosition") == 0.71)
    }
}
