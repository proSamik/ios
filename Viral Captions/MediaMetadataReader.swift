import AVFoundation
import Foundation

enum MediaMetadataReader {
    nonisolated static func videoMetadata(for url: URL) async throws -> VideoMetadata {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey])
        let fileSize = Int64(resourceValues.fileSize ?? resourceValues.totalFileSize ?? 0)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = tracks.first
        let naturalSize = try await videoTrack?.load(.naturalSize) ?? .zero
        let transform = try await videoTrack?.load(.preferredTransform) ?? .identity
        let transformed = naturalSize.applying(transform)
        let width = Int(abs(transformed.width).rounded())
        let height = Int(abs(transformed.height).rounded())

        return VideoMetadata(
            durationSeconds: max(0, duration.seconds.isFinite ? duration.seconds : 0),
            width: width,
            height: height,
            fileSize: fileSize,
            contentType: mimeType(for: url)
        )
    }

    nonisolated static func fileSize(for url: URL) throws -> Int64 {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey])
        return Int64(resourceValues.fileSize ?? resourceValues.totalFileSize ?? 0)
    }
}
