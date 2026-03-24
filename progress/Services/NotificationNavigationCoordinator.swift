import Foundation
import Combine

@MainActor
final class NotificationNavigationCoordinator: ObservableObject {
    static let shared = NotificationNavigationCoordinator()

    @Published private(set) var cameraOpenRequestToken: UUID?

    private init() {}

    func requestCameraOpenFromNotification() {
        cameraOpenRequestToken = UUID()
    }

    func consumeCameraOpenRequest() {
        cameraOpenRequestToken = nil
    }
}
