import SwiftUI

// MARK: - 顶栏录音按钮

struct AudioToolbarView: View {
    @ObservedObject var audio: AudioController
    @EnvironmentObject private var store: NoteStore

    let noteID: UUID
    let hasRecording: Bool
    var onError: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            IconButton(systemName: audio.mode == .recording ? "stop.fill" : "mic.fill",
                       isActive: audio.mode == .recording,
                       label: audio.mode == .recording ? "停止录音" : "录音") {
                toggleRecording()
            }

            if hasRecording {
                IconButton(systemName: audio.mode == .playing && !audio.isPaused ? "pause.fill" : "play.fill",
                           isActive: audio.mode == .playing,
                           label: "播放录音") {
                    togglePlayback()
                }
            }
        }
    }

    private func toggleRecording() {
        switch audio.mode {
        case .idle:
            Task { @MainActor in
                let granted = await audio.requestPermission()
                guard granted else {
                    onError("需要麦克风权限。请前往「设置 > Qian's Note」打开麦克风开关。")
                    return
                }
                store.prepareForRecording(noteID)
                do {
                    try audio.startRecording(to: store.audioURL(noteID: noteID))
                } catch {
                    onError("开始录音失败：\(error.localizedDescription)")
                }
            }

        case .recording:
            let duration = audio.stopRecording()
            store.finishRecording(noteID, duration: duration)

        case .playing:
            audio.stop()
        }
    }

    private func togglePlayback() {
        switch audio.mode {
        case .idle:
            do {
                try audio.play(url: store.audioURL(noteID: noteID))
            } catch {
                onError("播放失败：\(error.localizedDescription)")
            }
        case .playing:
            audio.togglePlayback()
        case .recording:
            break
        }
    }
}

// MARK: - 录音 / 播放浮条

struct AudioPanelView: View {
    @ObservedObject var audio: AudioController
    @EnvironmentObject private var store: NoteStore
    @Environment(\.horizontalSizeClass) private var sizeClass

    let noteID: UUID
    let title: String

    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        Group {
            switch audio.mode {
            case .recording:
                recordingBar
            case .playing:
                playbackBar
            case .idle:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: audio.mode)
    }

    private var recordingBar: some View {
        HStack(spacing: compact ? 8 : 14) {
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .opacity(audio.isPaused ? 0.35 : 1)

            Text(audio.time.clockText)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))

            Text(audio.isPaused ? "已暂停" : "正在录音")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !compact {
                Divider().frame(height: 20)
            }

            Button {
                audio.pauseRecording()
            } label: {
                Label(audio.isPaused ? "继续" : "暂停",
                      systemImage: audio.isPaused ? "play.fill" : "pause.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)

            Button {
                let duration = audio.stopRecording()
                store.finishRecording(noteID, duration: duration)
            } label: {
                Label("结束", systemImage: "stop.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)

            // 手机上放不下这句提示，只在大屏保留
            if !compact {
                Text("切换页面会自动生成书签")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, compact ? 14 : 18)
        .padding(.vertical, 10)
        .qianNoteGlassCapsule(tint: Color.red.opacity(0.10))
    }

    private var playbackBar: some View {
        HStack(spacing: compact ? 8 : 12) {
            Button {
                audio.togglePlayback()
            } label: {
                Image(systemName: audio.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.accent.opacity(0.14)))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)

            Text(audio.time.clockText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40)

            Slider(value: Binding(get: { audio.time },
                                  set: { audio.seek(to: $0) }),
                   in: 0...max(audio.duration, 0.1))
                // 手机上不能写死 180，否则整条超出屏幕
                .frame(minWidth: 70, maxWidth: compact ? .infinity : 180)
                .tint(Theme.accent)

            Text(audio.duration.clockText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40)

            Button {
                audio.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .qianNoteGlassCapsule()
        .padding(.horizontal, compact ? 10 : 0)
    }
}

// MARK: - 页面与录音同步

struct AudioSyncView: View {
    @ObservedObject var audio: AudioController
    @EnvironmentObject private var store: NoteStore

    let noteID: UUID
    let markers: [AudioMarker]
    @Binding var pageIndex: Int

    var body: some View {
        Color.clear
            .onChange(of: pageIndex) { _, newValue in
                guard audio.mode == .recording, !audio.isPaused else { return }
                store.addMarker(noteID: noteID, pageIndex: newValue, time: audio.time)
            }
            .onChange(of: audio.time) { _, value in
                guard audio.mode == .playing, !markers.isEmpty else { return }
                if let marker = markers.last(where: { $0.time <= value + 0.08 }),
                   marker.pageIndex != pageIndex,
                   markers.contains(where: { $0.pageIndex == marker.pageIndex }) {
                    pageIndex = marker.pageIndex
                }
            }
            .allowsHitTesting(false)
    }
}
