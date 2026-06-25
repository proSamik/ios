import AVFoundation
import CoreMedia
import Foundation
import Speech

struct LocalTranscriptSegment: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

struct LocalSpeechTranscription: Equatable {
    let locale: Locale
    let segments: [LocalTranscriptSegment]

    var srtText: String {
        segments.enumerated().map { index, segment in
            """
            \(index + 1)
            \(Self.srtTimestamp(segment.start)) --> \(Self.srtTimestamp(max(segment.end, segment.start + 0.8)))
            \(segment.text)
            """
        }
        .joined(separator: "\n\n")
    }

    private static func srtTimestamp(_ seconds: TimeInterval) -> String {
        let safeSeconds = max(0, seconds.isFinite ? seconds : 0)
        let milliseconds = Int((safeSeconds * 1000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let secs = (milliseconds % 60_000) / 1000
        let millis = milliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }
}

enum LocalSpeechTranscriber {
    enum TranscriptionError: LocalizedError {
        case unsupportedOS
        case unavailable
        case unsupportedLocale
        case noSpeech
        case audioExportFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedOS:
                return "Local transcription requires iOS, iPadOS, or macOS 26 or later."
            case .unavailable:
                return "Local transcription is not available on this device."
            case .unsupportedLocale:
                return "Local transcription does not support the selected language on this device."
            case .noSpeech:
                return "No speech was found in this video."
            case .audioExportFailed(let message):
                return message
            }
        }
    }

    @MainActor
    static func isSupported(languageCode: String) async -> Bool {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            return false
        }
        guard SpeechTranscriber.isAvailable else {
            return false
        }
        return await resolvedLocale(for: languageCode) != nil
    }

    @MainActor
    static func transcribeVideo(
        at videoURL: URL,
        languageCode: String,
        progress: @MainActor @escaping (Double, String) -> Void
    ) async throws -> LocalSpeechTranscription {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw TranscriptionError.unsupportedOS
        }
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.unavailable
        }
        guard let locale = await resolvedLocale(for: languageCode) else {
            throw TranscriptionError.unsupportedLocale
        }

        progress(0.08, "Preparing audio")
        let audioURL = try await exportAudioTrack(from: videoURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        progress(0.22, "Preparing speech model")
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status != .unsupported else {
            throw TranscriptionError.unsupportedLocale
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress(0.30, "Downloading speech model")
            try await request.downloadAndInstall()
        }

        progress(0.42, "Transcribing audio")
        let audioFile = try AVAudioFile(forReading: audioURL)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .whileInUse)
        )

        let collector = Task<[LocalTranscriptSegment], Error> {
            var segments: [LocalTranscriptSegment] = []
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = max(0, CMTimeGetSeconds(result.range.start))
                let duration = max(0.8, CMTimeGetSeconds(result.range.duration))
                segments.append(LocalTranscriptSegment(start: start, end: start + duration, text: text))
            }
            return segments
        }

        do {
            if let last = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            let segments = try await collector.value.sorted { $0.start < $1.start }
            guard !segments.isEmpty else {
                throw TranscriptionError.noSpeech
            }
            progress(1, "Transcript ready")
            return LocalSpeechTranscription(locale: locale, segments: segments)
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func resolvedLocale(for languageCode: String) async -> Locale? {
        let identifier: String
        if languageCode == "auto" {
            identifier = Locale.current.identifier
        } else {
            identifier = languageCode
        }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
    }

    private static func exportAudioTrack(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.audioExportFailed("Could not prepare the video's audio for local transcription.")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViralCaptions-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: outputURL)

        try await exporter.export(to: outputURL, as: .m4a)

        return outputURL
    }
}
