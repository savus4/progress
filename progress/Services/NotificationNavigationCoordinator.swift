import Foundation
import Combine

@MainActor
final class NotificationNavigationCoordinator: ObservableObject {
    static let shared = NotificationNavigationCoordinator()

    @Published private(set) var cameraOpenRequestToken: UUID?
    private(set) var cameraOpenRequestTimelineID: UUID?

    private init() {}

    func requestCameraOpenFromNotification(timelineID: UUID = TimelineIdentity.defaultID) {
        cameraOpenRequestTimelineID = timelineID
        cameraOpenRequestToken = UUID()
    }

    func consumeCameraOpenRequest() {
        cameraOpenRequestTimelineID = nil
        cameraOpenRequestToken = nil
    }
}
