import AVKit
import Combine
import SwiftUI

struct IntroductionVideoView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var isVideoReady = false
    @State private var didAttemptLoad = false

    let isActive: Bool

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .disabled(true)
                    .accessibilityLabel("Work in Progress app preview")
                    .onReceive(player.publisher(for: \.status).receive(on: RunLoop.main)) { status in
                        let ready = status == .readyToPlay
                        if isVideoReady != ready {
                            isVideoReady = ready
                        }
                    }
            } else {
                IntroductionVideoPlaceholder(isActive: isActive)
            }
        }
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
        .modifier(IntroductionEntrance(isActive: isActive && (player == nil ? didAttemptLoad : isVideoReady)))
        .onAppear(perform: prepareVideo)
        .onChange(of: scenePhase) { _, _ in updatePlayback() }
        .onChange(of: reduceMotion) { _, _ in updatePlayback() }
        .onChange(of: isActive) { _, _ in updatePlayback() }
        .onDisappear(perform: stopVideo)
    }

    private func prepareVideo() {
        didAttemptLoad = true
        guard player == nil,
              let url = Bundle.main.url(forResource: "Introduction", withExtension: "mp4")
                ?? Bundle.main.url(forResource: "Introduction", withExtension: "mov") else { return }

        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        player = queue
        updatePlayback()
    }

    private func updatePlayback() {
        if isActive && scenePhase == .active && !reduceMotion {
            player?.play()
        } else {
            player?.pause()
        }
    }

    private func stopVideo() {
        isVideoReady = false
        didAttemptLoad = false
        player?.pause()
        looper?.disableLooping()
        player?.removeAllItems()
        looper = nil
        player = nil
    }
}
