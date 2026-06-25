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
    @Published var isImportingVideo = false
    @Published var videoImportProgress: Double = 0
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
    @Published var outputRemoteURL: URL?
    @Published var outputSuggestedFileName: String?
    @Published var outputDownloadExpiresAt: Date?
    @Published var outputFileSize: Int64?
    @Published var alert: AppMessage?
    @Published var uploadQueue: [LocalUploadQueueItem]

    private let client = SubclipAPIClient()
    private var pollTask: Task<Void, Never>?
    private var importedVideoURL: URL?

    init() {
        self.apiKey = KeychainStore.readAPIKey()
        self.uploadQueue = LocalUploadQueueStore.load()
    }

    var isRendering: Bool {
        switch phase {
        case .creatingUpload, .uploadingVideo, .uploadingSRT, .startingJob, .polling:
            return true
        case .idle, .readingMedia, .downloading, .completed, .failed:
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

    var resultPreviewURL: URL? {
        outputURL ?? outputRemoteURL
    }

    var hasResult: Bool {
        resultPreviewURL != nil
    }

    var faceTrackApplies: Bool {
        guard let sourceAspectRatio = selectedVideo?.metadata.inferredAspectRatio else {
            return true
        }
        return sourceAspectRatio != aspectRatio
    }

    var effectiveFaceTrack: Bool {
        faceTrack && (placement == .none || faceTrackApplies)
    }

    func selectPlacement(_ nextPlacement: CaptionPlacement) {
        placement = nextPlacement
        if nextPlacement == .none {
            faceTrack = true
        }
    }

    func setFaceTrack(_ isEnabled: Bool) {
        faceTrack = isEnabled
        if isEnabled {
            placement = .none
        } else if placement == .none {
            placement = .bottom
        }
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
        outputRemoteURL = nil
        outputSuggestedFileName = nil
        outputDownloadExpiresAt = nil
        outputFileSize = nil
        latestStatus = nil
        estimatedCredits = nil
        creditsUsed = nil
        projectId = nil
        runId = nil
        progress = 0
        phase = .idle
        statusMessage = selectedVideo == nil ? "Choose a video to begin." : "Ready to add captions."
    }

    func render() {
        guard canRender else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.runRender()
        }
    }

    func cancelRender() {
        pollTask?.cancel()
        pollTask = nil
        if isRendering {
            phase = .idle
            progress = 0
            statusMessage = selectedVideo == nil ? "Choose a video to begin." : "Ready to add captions."
        }
    }

    func beginVideoImport() {
        resetResult()
        isImportingVideo = true
        videoImportProgress = 0.12
        phase = .readingMedia
        statusMessage = "Loading video..."
    }

    func failVideoImport(message: String) {
        isImportingVideo = false
        videoImportProgress = 0
        phase = .failed
        statusMessage = "Could not read that video."
        alert = AppMessage(title: "Video import failed", message: message)
    }

    func clearUploadQueue() {
        uploadQueue.removeAll()
        LocalUploadQueueStore.save(uploadQueue)
    }

    private func setVideo(from url: URL) async {
        releaseVideoScope()
        beginVideoImport()

        let didStartScope = url.startAccessingSecurityScopedResource()
        var scopeActive = didStartScope
        var copiedURL: URL?
        do {
            let originalFileName = friendlyVideoFileName(for: url)
            let localURL = try await Task.detached(priority: .userInitiated) {
                try Self.copyVideoIntoImports(from: url, fallbackFileName: originalFileName)
            }.value
            copiedURL = localURL
            videoImportProgress = 0.45
            if scopeActive {
                url.stopAccessingSecurityScopedResource()
                scopeActive = false
            }

            let metadata = try await MediaMetadataReader.videoMetadata(for: localURL)
            videoImportProgress = 0.82
            importedVideoURL = localURL
            selectedVideo = SelectedVideo(
                url: localURL,
                fileName: originalFileName,
                securityScoped: false,
                metadata: metadata
            )
            outputFileName = defaultOutputName(for: originalFileName)
            phase = .idle
            statusMessage = "Ready to add captions."
            progress = 0
            videoImportProgress = 1
            isImportingVideo = false
        } catch {
            if scopeActive {
                url.stopAccessingSecurityScopedResource()
            }
            if let copiedURL {
                try? FileManager.default.removeItem(at: copiedURL)
            }
            selectedVideo = nil
            failVideoImport(message: error.localizedDescription)
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
            outputRemoteURL = nil
            outputSuggestedFileName = nil
            outputDownloadExpiresAt = nil
            outputFileSize = nil
            latestStatus = nil
            creditsUsed = nil
            projectId = nil
            runId = nil
            estimatedCredits = nil
            phase = .creatingUpload
            progress = 0.08
            statusMessage = "Creating secure upload URLs..."
            let shouldDeclareDimensions = selectedVideo.metadata.inferredAspectRatio != aspectRatio

            let uploadPayload = CreateUploadRequest(
                projectName: selectedVideo.fileName.replacingOccurrences(of: ".\(selectedVideo.url.pathExtension)", with: ""),
                video: .init(
                    fileName: selectedVideo.fileName,
                    contentType: selectedVideo.metadata.contentType,
                    fileSize: selectedVideo.metadata.fileSize,
                    durationSeconds: selectedVideo.metadata.durationSeconds,
                    width: shouldDeclareDimensions ? selectedVideo.metadata.width : nil,
                    height: shouldDeclareDimensions ? selectedVideo.metadata.height : nil
                ),
                srt: selectedSRT.map {
                    .init(fileName: $0.fileName, contentType: "text/plain", fileSize: $0.fileSize)
                }
            )

            let upload = try await client.createUpload(apiKey: trimmedKey, payload: uploadPayload)
            projectId = upload.projectId
            addQueueItem(
                projectId: upload.projectId,
                fileName: selectedVideo.fileName,
                status: "Upload created"
            )

            phase = .uploadingVideo
            progress = 0.18
            statusMessage = "Uploading \(selectedVideo.fileName)..."
            updateQueueItem(projectId: upload.projectId, status: "Uploading")
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
            updateQueueItem(projectId: upload.projectId, status: "Starting render")
            let start = try await client.startJob(
                apiKey: trimmedKey,
                payload: StartJobRequest(
                    projectId: upload.projectId,
                    language: selectedLanguage,
                    templateId: selectedTemplateId,
                    aspectRatio: aspectRatio.rawValue,
                    placement: placement.apiValue,
                    faceTrack: effectiveFaceTrack ? true : nil,
                    outputFileName: normalizedOutputFileName()
                )
            )
            runId = start.runId
            estimatedCredits = start.estimatedCredits
            updateQueueItem(projectId: upload.projectId, status: "Rendering")

            let completeStatus = try await pollUntilReady(apiKey: trimmedKey, projectId: upload.projectId)
            creditsUsed = completeStatus.creditsUsed

            let info = try await client.downloadInfo(apiKey: trimmedKey, projectId: upload.projectId)
            outputRemoteURL = info.downloadUrl
            outputSuggestedFileName = info.fileName ?? normalizedOutputFileName() ?? "captioned-video.mp4"
            outputDownloadExpiresAt = downloadExpiryDate(from: info)
            outputFileSize = info.fileSize
            phase = .completed
            progress = 1
            statusMessage = "Ready to download."
            updateQueueItem(
                projectId: upload.projectId,
                status: "Completed",
                outputFileName: outputSuggestedFileName,
                outputFileSize: info.fileSize,
                creditsUsed: completeStatus.creditsUsed,
                downloadExpiresAt: outputDownloadExpiresAt
            )
        } catch is CancellationError {
            phase = .idle
            statusMessage = "Render canceled."
            if let projectId {
                updateQueueItem(projectId: projectId, status: "Canceled")
            }
        } catch {
            phase = .failed
            statusMessage = "Render failed."
            if let projectId {
                updateQueueItem(projectId: projectId, status: "Failed")
            }
            alert = AppMessage(title: "Render failed", message: error.localizedDescription)
        }
    }

    func saveOutputCopy(to destination: URL) {
        guard let outputURL else { return }
        do {
            var destinationURL = destination
            if destinationURL.pathExtension.isEmpty {
                destinationURL.appendPathExtension("mp4")
            }
            if outputURL.standardizedFileURL == destinationURL.standardizedFileURL {
                alert = AppMessage(title: "MP4 saved", message: destinationURL.path)
                return
            }
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: outputURL, to: destinationURL)
            alert = AppMessage(title: "MP4 saved", message: destinationURL.path)
        } catch {
            alert = AppMessage(title: "Could not save MP4", message: error.localizedDescription)
        }
    }

    func downloadCurrentOutput() async -> URL? {
        if let outputURL {
            return outputURL
        }
        guard let outputRemoteURL else {
            alert = AppMessage(title: "Download unavailable", message: "The rendered MP4 is not ready yet.")
            return nil
        }

        do {
            phase = .downloading
            statusMessage = "Downloading final MP4..."
            let localURL = try await client.downloadFile(
                from: outputRemoteURL,
                suggestedFileName: outputSuggestedFileName ?? normalizedOutputFileName() ?? "captioned-video.mp4"
            )
            outputURL = localURL
            phase = .completed
            statusMessage = "Downloaded."
            return localURL
        } catch {
            phase = .completed
            alert = AppMessage(title: "Could not download MP4", message: error.localizedDescription)
            return nil
        }
    }

    func downloadHistoryItem(_ item: LocalUploadQueueItem) async -> URL? {
        guard item.isDownloadAvailable else {
            alert = AppMessage(title: "Download expired", message: "This history item is past the 58-minute download window.")
            return nil
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            alert = AppMessage(title: "API key required", message: "Enter a Subclip API key to refresh this download.")
            return nil
        }

        do {
            let info = try await client.downloadInfo(apiKey: trimmedKey, projectId: item.projectId)
            let fileName = info.fileName ?? item.outputFileName ?? "captioned-video.mp4"
            let localURL = try await client.downloadFile(from: info.downloadUrl, suggestedFileName: fileName)
            outputURL = localURL
            outputRemoteURL = info.downloadUrl
            outputSuggestedFileName = fileName
            outputFileSize = info.fileSize
            outputDownloadExpiresAt = downloadExpiryDate(from: info)
            updateQueueItem(
                projectId: item.projectId,
                status: "Completed",
                outputFileName: fileName,
                outputFileSize: info.fileSize,
                creditsUsed: item.creditsUsed,
                downloadExpiresAt: outputDownloadExpiresAt
            )
            return localURL
        } catch {
            alert = AppMessage(title: "Could not download MP4", message: error.localizedDescription)
            return nil
        }
    }

    func saveOutputToDefaultFolder() {
        guard let outputURL else { return }
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let destination = base
            .appendingPathComponent("Viral Captions", isDirectory: true)
            .appendingPathComponent(outputURL.lastPathComponent)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            saveOutputCopy(to: destination)
        } catch {
            alert = AppMessage(title: "Could not save MP4", message: error.localizedDescription)
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
        return "Captioned-\(base).mp4"
    }

    private func friendlyVideoFileName(for url: URL) -> String {
        let sanitized = sanitizedFileName(url.lastPathComponent, fallback: "video.mp4")
        let fallbackExtension = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let base = URL(fileURLWithPath: sanitized).deletingPathExtension().lastPathComponent
        let uuidPattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#
        let isUUIDLike = base.range(of: uuidPattern, options: .regularExpression) != nil
            || ((base.filter(\.isNumber).count + base.filter(\.isLetter).count) >= 24 && base.contains("-"))

        guard isUUIDLike else {
            return sanitized
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "Video-\(formatter.string(from: Date())).\(fallbackExtension)"
    }

    private func normalizedOutputFileName() -> String? {
        let cleaned = sanitizedFileName(outputFileName, fallback: "captioned-video.mp4")
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return cleaned.lowercased().hasSuffix(".mp4") ? cleaned : "\(cleaned).mp4"
    }

    private func addQueueItem(projectId: String, fileName: String, status: String) {
        uploadQueue.removeAll { $0.projectId == projectId }
        uploadQueue.insert(
            LocalUploadQueueItem(
                projectId: projectId,
                fileName: fileName,
                templateId: selectedTemplateId,
                aspectRatio: aspectRatio.rawValue,
                status: status,
                outputFileName: normalizedOutputFileName()
            ),
            at: 0
        )
        LocalUploadQueueStore.save(uploadQueue)
    }

    private func updateQueueItem(
        projectId: String,
        status: String,
        outputFileName: String? = nil,
        outputFileSize: Int64? = nil,
        creditsUsed: Double? = nil,
        downloadExpiresAt: Date? = nil
    ) {
        guard let index = uploadQueue.firstIndex(where: { $0.projectId == projectId }) else { return }
        uploadQueue[index].status = status
        if let outputFileName {
            uploadQueue[index].outputFileName = outputFileName
        }
        if let outputFileSize {
            uploadQueue[index].outputFileSize = outputFileSize
        }
        if let creditsUsed {
            uploadQueue[index].creditsUsed = creditsUsed
        }
        if let downloadExpiresAt {
            uploadQueue[index].downloadExpiresAt = downloadExpiresAt
        }
        LocalUploadQueueStore.save(uploadQueue)
    }

    private func downloadExpiryDate(from info: DownloadInfoResponse) -> Date {
        if let expiresAt = info.expiresAt {
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: expiresAt) {
                return min(date, Date().addingTimeInterval(58 * 60))
            }
        }
        if let expiresIn = info.expiresIn {
            return Date().addingTimeInterval(max(0, min(TimeInterval(expiresIn), 58 * 60)))
        }
        return Date().addingTimeInterval(58 * 60)
    }

    private func releaseVideoScope() {
        if selectedVideo?.securityScoped == true {
            selectedVideo?.url.stopAccessingSecurityScopedResource()
        }
        if let importedVideoURL {
            try? FileManager.default.removeItem(at: importedVideoURL)
            self.importedVideoURL = nil
        }
        selectedVideo = nil
    }

    nonisolated private static func copyVideoIntoImports(from sourceURL: URL, fallbackFileName: String) throws -> URL {
        let importsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViralCaptionsImports", isDirectory: true)
        try FileManager.default.createDirectory(at: importsDirectory, withIntermediateDirectories: true)

        let fallbackExtension = URL(fileURLWithPath: fallbackFileName).pathExtension
        let fileExtension = sourceURL.pathExtension.isEmpty
            ? (fallbackExtension.isEmpty ? "mp4" : fallbackExtension)
            : sourceURL.pathExtension
        let destination = importsDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

}
