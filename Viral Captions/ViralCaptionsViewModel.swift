import Combine
import Foundation

@MainActor
final class ViralCaptionsViewModel: ObservableObject {
    enum RenderPhase: Equatable {
        case idle
        case readingMedia
        case creatingUpload
        case uploadingVideo
        case uploadingSRT
        case startingJob
        case polling
        case downloading
        case completed
        case failed

        var label: String {
            switch self {
            case .idle:
                return "Ready"
            case .readingMedia:
                return "Reading media"
            case .creatingUpload:
                return "Creating upload"
            case .uploadingVideo:
                return "Uploading video"
            case .uploadingSRT:
                return "Uploading SRT"
            case .startingJob:
                return "Starting render"
            case .polling:
                return "Rendering"
            case .downloading:
                return "Downloading result"
            case .completed:
                return "Completed"
            case .failed:
                return "Failed"
            }
        }
    }

    @Published var apiKey: String
    @Published var selectedVideo: SelectedVideo?
    @Published var selectedSRT: SelectedSRT?
    @Published var selectedTemplateId = "bold-clean"
    @Published var selectedLanguage = "auto"
    @Published var aspectRatio: OutputAspectRatio = .vertical
    @Published var placement: CaptionPlacement = .bottom
    @Published var faceTrack = true
    @Published var outputFileName = ""
    @Published var phase: RenderPhase = .idle
    @Published var statusMessage = "Choose a video to begin."
    @Published var progress: Double = 0
    @Published var projectId: String?
    @Published var runId: String?
    @Published var estimatedCredits: Double?
    @Published var creditsUsed: Double?
    @Published var latestStatus: JobStatusResponse?
    @Published var outputURL: URL?
    @Published var outputFileSize: Int64?
    @Published var alert: AppMessage?

    private let client = SubclipAPIClient()
    private var pollTask: Task<Void, Never>?

    init() {
        self.apiKey = KeychainStore.readAPIKey()
    }

    var isRendering: Bool {
        switch phase {
        case .creatingUpload, .uploadingVideo, .uploadingSRT, .startingJob, .polling, .downloading:
            return true
        case .idle, .readingMedia, .completed, .failed:
            return false
        }
    }

    var canRender: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedVideo != nil
            && !isRendering
    }

    var selectedTemplate: CaptionTemplate {
        CaptionTemplate.all.first(where: { $0.id == selectedTemplateId }) ?? CaptionTemplate.all[0]
    }

    func saveAPIKey() {
        do {
            try KeychainStore.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            alert = AppMessage(title: "API key saved", message: "Your key is stored locally in Keychain.")
        } catch {
            alert = AppMessage(title: "Could not save key", message: error.localizedDescription)
        }
    }

    func clearAPIKey() {
        do {
            try KeychainStore.deleteAPIKey()
            apiKey = ""
            alert = AppMessage(title: "API key removed", message: "The saved key was removed from Keychain.")
        } catch {
            alert = AppMessage(title: "Could not remove key", message: error.localizedDescription)
        }
    }

    func importVideo(from url: URL) {
        Task {
            await setVideo(from: url)
        }
    }

    func importSRT(from url: URL) {
        Task {
            await setSRT(from: url)
        }
    }

    func removeSRT() {
        if selectedSRT?.securityScoped == true {
            selectedSRT?.url.stopAccessingSecurityScopedResource()
        }
        selectedSRT = nil
    }

    func resetResult() {
        pollTask?.cancel()
        outputURL = nil
        outputFileSize = nil
        latestStatus = nil
        estimatedCredits = nil
        creditsUsed = nil
        projectId = nil
        runId = nil
        progress = 0
        phase = .idle
        statusMessage = selectedVideo == nil ? "Choose a video to begin." : "Ready to render."
    }

    func render() {
        guard canRender else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.runRender()
        }
    }

    private func setVideo(from url: URL) async {
        releaseVideoScope()
        resetResult()
        phase = .readingMedia
        statusMessage = "Reading video metadata..."

        let didStartScope = url.startAccessingSecurityScopedResource()
        do {
            let metadata = try await MediaMetadataReader.videoMetadata(for: url)
            selectedVideo = SelectedVideo(
                url: url,
                fileName: sanitizedFileName(url.lastPathComponent, fallback: "video.mp4"),
                securityScoped: didStartScope,
                metadata: metadata
            )
            outputFileName = defaultOutputName(for: url.lastPathComponent)
            phase = .idle
            statusMessage = "Ready to render."
            progress = 0
        } catch {
            if didStartScope {
                url.stopAccessingSecurityScopedResource()
            }
            selectedVideo = nil
            phase = .failed
            statusMessage = "Could not read that video."
            alert = AppMessage(title: "Video import failed", message: error.localizedDescription)
        }
    }

    private func setSRT(from url: URL) async {
        removeSRT()
        let didStartScope = url.startAccessingSecurityScopedResource()
        do {
            let size = try MediaMetadataReader.fileSize(for: url)
            selectedSRT = SelectedSRT(
                url: url,
                fileName: sanitizedFileName(url.lastPathComponent, fallback: "captions.srt"),
                fileSize: size,
                securityScoped: didStartScope
            )
        } catch {
            if didStartScope {
                url.stopAccessingSecurityScopedResource()
            }
            alert = AppMessage(title: "SRT import failed", message: error.localizedDescription)
        }
    }

    private func runRender() async {
        guard let selectedVideo else { return }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            alert = AppMessage(title: "API key required", message: "Enter a Subclip API key with dynamic_captions access.")
            return
        }

        do {
            outputURL = nil
            outputFileSize = nil
            latestStatus = nil
            creditsUsed = nil
            phase = .creatingUpload
            progress = 0.08
            statusMessage = "Creating secure upload URLs..."

            let uploadPayload = CreateUploadRequest(
                projectName: selectedVideo.fileName.replacingOccurrences(of: ".\(selectedVideo.url.pathExtension)", with: ""),
                video: .init(
                    fileName: selectedVideo.fileName,
                    contentType: selectedVideo.metadata.contentType,
                    fileSize: selectedVideo.metadata.fileSize,
                    durationSeconds: selectedVideo.metadata.durationSeconds,
                    width: selectedVideo.metadata.width,
                    height: selectedVideo.metadata.height
                ),
                srt: selectedSRT.map {
                    .init(fileName: $0.fileName, contentType: "text/plain", fileSize: $0.fileSize)
                }
            )

            let upload = try await client.createUpload(apiKey: trimmedKey, payload: uploadPayload)
            projectId = upload.projectId

            phase = .uploadingVideo
            progress = 0.18
            statusMessage = "Uploading \(selectedVideo.fileName)..."
            try await client.uploadFile(
                fileURL: selectedVideo.url,
                uploadURL: upload.video.uploadUrl,
                contentType: upload.video.contentType ?? selectedVideo.metadata.contentType,
                fileSize: selectedVideo.metadata.fileSize
            )

            if let selectedSRT, let srtUpload = upload.srt {
                phase = .uploadingSRT
                progress = 0.28
                statusMessage = "Uploading \(selectedSRT.fileName)..."
                try await client.uploadFile(
                    fileURL: selectedSRT.url,
                    uploadURL: srtUpload.uploadUrl,
                    contentType: "text/plain",
                    fileSize: selectedSRT.fileSize
                )
            }

            phase = .startingJob
            progress = 0.34
            statusMessage = "Starting Subclip render..."
            let start = try await client.startJob(
                apiKey: trimmedKey,
                payload: StartJobRequest(
                    projectId: upload.projectId,
                    language: selectedLanguage,
                    templateId: selectedTemplateId,
                    aspectRatio: aspectRatio.rawValue,
                    placement: placement.rawValue,
                    faceTrack: faceTrack,
                    outputFileName: normalizedOutputFileName()
                )
            )
            runId = start.runId
            estimatedCredits = start.estimatedCredits

            let completeStatus = try await pollUntilReady(apiKey: trimmedKey, projectId: upload.projectId)
            creditsUsed = completeStatus.creditsUsed

            phase = .downloading
            progress = 0.94
            statusMessage = "Preparing download..."
            let info = try await client.downloadInfo(apiKey: trimmedKey, projectId: upload.projectId)
            statusMessage = "Downloading final MP4..."
            let localURL = try await client.downloadFile(
                from: info.downloadUrl,
                suggestedFileName: info.fileName ?? normalizedOutputFileName() ?? "captioned-video.mp4"
            )
            outputURL = localURL
            outputFileSize = info.fileSize
            phase = .completed
            progress = 1
            statusMessage = "Render complete."
        } catch is CancellationError {
            phase = .idle
            statusMessage = "Render canceled."
        } catch {
            phase = .failed
            statusMessage = "Render failed."
            alert = AppMessage(title: "Render failed", message: error.localizedDescription)
        }
    }

    private func pollUntilReady(apiKey: String, projectId: String) async throws -> JobStatusResponse {
        phase = .polling
        statusMessage = "Rendering on Subclip..."

        for attempt in 0..<720 {
            try Task.checkCancellation()
            let status = try await client.jobStatus(apiKey: apiKey, projectId: projectId)
            latestStatus = status
            let serverProgress = max(0, min(100, status.progress ?? 0)) / 100
            progress = min(0.92, 0.36 + (serverProgress * 0.54))
            statusMessage = "\(status.normalizedStatus) \(Int(serverProgress * 100))%"

            if status.outputReady {
                return status
            }

            if status.status.lowercased() == "failed" {
                throw SubclipAPIError(message: status.errorMessage ?? "Subclip render failed.")
            }

            let delaySeconds: UInt64 = attempt < 24 ? 5 : 15
            try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
        }

        throw SubclipAPIError(message: "Timed out while waiting for the render to finish.")
    }

    private func defaultOutputName(for fileName: String) -> String {
        let base = fileName.replacingOccurrences(
            of: "\\.(mp4|mov|webm|mkv|avi|m4v|mpg|mpeg)$",
            with: "",
            options: .regularExpression
        )
        return "\(base)-captions.mp4"
    }

    private func normalizedOutputFileName() -> String? {
        let cleaned = sanitizedFileName(outputFileName, fallback: "captioned-video.mp4")
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return cleaned.lowercased().hasSuffix(".mp4") ? cleaned : "\(cleaned).mp4"
    }

    private func releaseVideoScope() {
        if selectedVideo?.securityScoped == true {
            selectedVideo?.url.stopAccessingSecurityScopedResource()
        }
        selectedVideo = nil
    }

}
