import SwiftUI
import AVFoundation

// Compact inline mic button for any TextEditor or TextField.
// Tap to record, tap again to stop. Transcribes via BackendService.transcribeAudio
// and appends the result to the bound text. Shows a pulse while recording,
// a spinner while transcribing, and an alert on failure.
struct VoiceDictationButton: View {
    @Binding var text: String

    @EnvironmentObject var theme: ThemeManager

    @State private var isRecording = false
    @State private var isTranscribing = false
    @State private var audioRecorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        Button {
            guard !isTranscribing else { return }
            if isRecording { stopRecording() } else { startRecording() }
        } label: {
            ZStack {
                if isTranscribing {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle")
                        .font(.system(size: 22))
                        .foregroundColor(isRecording ? .red : theme.accent)
                        .symbolEffect(.pulse, isActive: isRecording)
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .alert("Transcription failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dictation_\(UUID().uuidString).m4a")
            recordingURL = url
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.record()
            isRecording = true
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        audioRecorder?.stop()
        isRecording = false
        Task { await transcribe() }
    }

    private func transcribe() async {
        guard let url = recordingURL else { return }
        isTranscribing = true
        defer { isTranscribing = false }
        do {
            let audioData = try Data(contentsOf: url)
            let result = try await BackendService.transcribeAudio(audioData: audioData)
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            text = text.isEmpty ? trimmed : text + " " + trimmed
        } catch {
            errorMessage = "Transcription failed. Is your Mac backend running?\n\(error.localizedDescription)"
        }
    }
}
