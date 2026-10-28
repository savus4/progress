import Foundation
import Testing
@testable import progress

@MainActor
struct PhotoImportSettingsRecoveryTests {
    @Test("Settings recovery retains the chosen import and timeline exactly once", arguments: [PhotoImportMethod.photos, .album])
    func roundTrip(method: PhotoImportMethod) throws {
        let suite = "PhotoImportSettingsRecoveryTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let timelineID = UUID()
        PhotoImportSettingsRecovery.save(
            PhotoImportResumeRequest(method: method, timelineID: timelineID, createdAt: now), defaults: defaults
        )

        let recovered = try #require(PhotoImportSettingsRecovery.consume(defaults: defaults, now: now))
        #expect(recovered.method == method)
        #expect(recovered.timelineID == timelineID)
        #expect(PhotoImportSettingsRecovery.consume(defaults: defaults, now: now) == nil)
    }

    @Test("Old settings trips do not reopen an unexpected importer")
    func expiredRequest() throws {
        let suite = "PhotoImportSettingsRecoveryTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        PhotoImportSettingsRecovery.save(PhotoImportResumeRequest(
            method: .photos, timelineID: UUID(), createdAt: now.addingTimeInterval(-3600)
        ), defaults: defaults)
        #expect(PhotoImportSettingsRecovery.consume(defaults: defaults, now: now) == nil)
    }

    @Test("Returning without a restart clears the saved recovery")
    func clearsAfterReturn() throws {
        let suite = "PhotoImportSettingsRecoveryTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        PhotoImportSettingsRecovery.save(PhotoImportResumeRequest(
            method: .album, timelineID: UUID(), createdAt: Date()
        ), defaults: defaults)
        PhotoImportSettingsRecovery.clear(defaults: defaults)
        #expect(PhotoImportSettingsRecovery.consume(defaults: defaults) == nil)
    }
}
