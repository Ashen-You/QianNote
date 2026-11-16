import Foundation
import AVFoundation
import Combine
import UIKit

/// 录音 / 播放控制器。同一时间只做一件事。
final class AudioController: NSObject, ObservableObject {

    enum Mode: String {
        case idle
        case recording
        case playing
    }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var isPaused = false
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var currentURL: URL?

    // MARK: - 权限

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - 录音

    func startRecording(to url: URL) throws {
        try activateSession(category: .playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.delegate = self
        recorder.record()

        self.recorder = recorder
        currentURL = url
        mode = .recording
        isPaused = false
        time = 0
        duration = 0
        startTimer()
    }

    func pauseRecording() {
        guard mode == .recording, let recorder else { return }
        if recorder.isRecording {
            recorder.pause()
            isPaused = true
            stopTimer()
        } else {
            recorder.record()
            isPaused = false
            startTimer()
        }
    }

    @discardableResult
    func stopRecording() -> TimeInterval {
        guard let recorder else { return 0 }
        let total = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        mode = .idle
        isPaused = false
        time = total
        duration = total
        stopTimer()
        deactivateSession()
        return total
    }

    // MARK: - 播放

    func play(url: URL) throws {
        try activateSession(category: .playback, options: [])

        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        player.play()

        self.player = player
        currentURL = url
        mode = .playing
        isPaused = false
        duration = player.duration
        time = 0
        startTimer()
    }

    func togglePlayback() {
        guard mode == .playing, let player else { return }
        if player.isPlaying {
            player.pause()
            isPaused = true
            stopTimer()
        } else {
            player.play()
            isPaused = false
            startTimer()
        }
    }

    func seek(to time: TimeInterval) {
        guard mode == .playing, let player else { return }
        let target = min(max(time, 0), player.duration)
        player.currentTime = target
        self.time = target
    }

    func stop() {
        if mode == .recording {
            stopRecording()
            return
        }
        player?.stop()
        player = nil
        mode = .idle
        isPaused = false
        stopTimer()
        deactivateSession()
    }

    // MARK: - 计时器

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        switch mode {
        case .recording:
            if let recorder, recorder.isRecording {
                time = recorder.currentTime
            }
        case .playing:
            if let player {
                time = player.currentTime
                duration = player.duration
            }
        case .idle:
            break
        }
    }

    // MARK: - Audio Session

    private func activateSession(category: AVAudioSession.Category,
                                 options: AVAudioSession.CategoryOptions) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(category, mode: .default, options: options)
        try session.setActive(true)
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - 代理

extension AudioController: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if self.mode == .recording {
                self.stopRecording()
            }
        }
    }
}

extension AudioController: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            self.mode = .idle
            self.isPaused = false
            self.time = self.duration
            self.stopTimer()
            self.deactivateSession()
        }
    }
}

// MARK: - 格式化

extension TimeInterval {
    var clockText: String {
        let total = Int(self.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
