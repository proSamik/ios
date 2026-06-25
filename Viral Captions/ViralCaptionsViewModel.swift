import Combine
import CryptoKit
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
    @Published var placement: CaptionPlacement = .none
    @Published var faceTrack = true
    @Published var autoTranscribe = true
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
    @Published var resultAspectRatio: OutputAspectRatio?
    @Published var alert: AppMessage?
    @Published var uploadQueue: [LocalUploadQueueItem]
    @Published var localTranscriptionSupported = false
    @Published var isTranscribing = false
    @Published var transcriptionProgress: Double = 0
    @Published var transcriptionStatus = ""
    @Published var isSRTEditorPresented = false
    @Published var srtDraft = ""
    @Published var isCheckingQuota = false
    @Published var quotaInfo: QuotaResponse?
    @Published var apiKeyValidated: Bool

    private let client = SubclipAPIClient()
    private var pollTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var outputCacheTask: Task<URL?, Never>?
    private var importedVideoURL: URL?
    nonisolated private static let validatedAPIKeyHashKey = "validatedAPIKeyHash"

    init() {
        let storedAPIKey = KeychainStore.readAPIKey()
        self.apiKey = storedAPIKey
        self.apiKeyValidated = Self.storedValidationMatches(storedAPIKey)
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
            && apiKeyValidated
            && selectedVideo != nil
            && (autoTranscribe || selectedSRT != nil)
            && !isRendering
    }

    var needsAPIKeyValidation: Bool {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !apiKeyValidated
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
        faceTrack
    }

    func selectPlacement(_ nextPlacement: CaptionPlacement) {
        placement = nextPlacement
    }

    func setFaceTrack(_ isEnabled: Bool) {
        faceTrack = isEnabled
    }

    func setAutoTranscribe(_ isEnabled: Bool) {
        autoTranscribe = isEnabled
    }

    func apiKeyDidChange() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKeyValidated = Self.storedValidationMatches(trimmedKey)
        if !apiKeyValidated {
            quotaInfo = nil
        }
    }

    func saveAPIKey() {
        Task {
            await validateAndSaveAPIKey()
        }
    }

    func validateAndSaveAPIKey() async {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            apiKeyValidated = false
            quotaInfo = nil
            alert = AppMessage(title: "API key required", message: "Enter your Subclip API key to continue.")
            return
        }

        isCheckingQuota = true
        do {
            let quota = try await client.quota(apiKey: trimmedKey)
            guard quota.aiCredits.allowed else {
                throw SubclipAPIError(message: "This API key does not have enough AI credits.")
            }
            try KeychainStore.saveAPIKey(trimmedKey)
            UserDefaults.standard.set(Self.apiKeyHash(trimmedKey), forKey: Self.validatedAPIKeyHashKey)
            apiKey = trimmedKey
            quotaInfo = quota
            apiKeyValidated = true
            alert = AppMessage(title: "API key ready", message: quotaSuccessMessage(for: quota))
        } catch {
            apiKeyValidated = false
            quotaInfo = nil
            alert = AppMessage(title: "Could not verify API key", message: error.localizedDescription)
        }
        isCheckingQuota = false
    }

    func clearAPIKey() {
        do {
            try KeychainStore.deleteAPIKey()
            apiKey = ""
            apiKeyValidated = false
            quotaInfo = nil
            UserDefaults.standard.removeObject(forKey: Self.validatedAPIKeyHashKey)
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
        srtDraft = ""
    }

    func refreshLocalTranscriptionSupport() async {
        localTranscriptionSupported = await LocalSpeechTranscriber.isSupported(languageCode: selectedLanguage)
    }

    func transcribeSelectedVideo() {
        guard let selectedVideo, localTranscriptionSupported, !isTranscribing else { return }
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            await self?.runLocalTranscription(videoURL: selectedVideo.url, videoFileName: selectedVideo.fileName)
        }
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTranscribing = false
        transcriptionProgress = 0
        transcriptionStatus = ""
    }

    func openSRTEditor() {
        guard let selectedSRT else { return }
        do {
            srtDraft = try String(contentsOf: selectedSRT.url, encoding: .utf8)
            isSRTEditorPresented = true
        } catch {
            alert = AppMessage(title: "Could not open SRT", message: error.localizedDescription)
        }
    }

    func saveSRTDraft() {
        let text = srtDraft
        let fileName = selectedSRT?.fileName ?? defaultSRTFileName()
        Task {
            do {
                try await setSRTText(text, fileName: fileName)
                isSRTEditorPresented = false
            } catch {
                alert = AppMessage(title: "Could not save SRT", message: error.localizedDescription)
            }
        }
    }

    func resetResult() {
        pollTask?.cancel()
        outputCacheTask?.cancel()
        outputCacheTask = nil
        outputURL = nil
        outputRemoteURL = nil
        outputSuggestedFileName = nil
        outputDownloadExpiresAt = nil
        outputFileSize = nil
        resultAspectRatio = nil
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
            srtDraft = try String(contentsOf: url, encoding: .utf8)
        } catch {
            if didStartScope {
                url.stopAccessingSecurityScopedResource()
            }
            alert = AppMessage(title: "SRT import failed", message: error.localizedDescription)
        }
    }

    private func setSRTText(_ text: String, fileName: String) async throws {
        let safeFileName = sanitizedFileName(fileName, fallback: defaultSRTFileName())
        let result = try await Task.detached(priority: .userInitiated) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ViralCaptionsSRT", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let outputURL = directory.appendingPathComponent(safeFileName)
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try text.write(to: outputURL, atomically: true, encoding: .utf8)
            let size = try MediaMetadataReader.fileSize(for: outputURL)
            return (outputURL, size)
        }.value

        removeSRT()
        selectedSRT = SelectedSRT(
            url: result.0,
            fileName: safeFileName,
            fileSize: result.1,
            securityScoped: false
        )
        srtDraft = text
    }

    private func runLocalTranscription(videoURL: URL, videoFileName: String) async {
        let languageCode = selectedLanguage
        isTranscribing = true
        transcriptionProgress = 0.02
        transcriptionStatus = "Starting transcription"

        do {
            let transcript = try await LocalSpeechTranscriber.transcribeVideo(
                at: videoURL,
                languageCode: languageCode
            ) { [weak self] progress, status in
                guard let self else { return }
                self.transcriptionProgress = progress
                self.transcriptionStatus = status
            }

            try Task.checkCancellation()
            let srtText = transcript.srtText
            try await setSRTText(srtText, fileName: defaultSRTFileName(for: videoFileName))
            transcriptionProgress = 1
            transcriptionStatus = "Transcript ready"
            isTranscribing = false
            isSRTEditorPresented = true
        } catch is CancellationError {
            isTranscribing = false
            transcriptionProgress = 0
            transcriptionStatus = ""
        } catch {
            isTranscribing = false
            transcriptionProgress = 0
            transcriptionStatus = ""
            alert = AppMessage(title: "Could not transcribe audio", message: error.localizedDescription)
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
            outputCacheTask?.cancel()
            outputCacheTask = nil
            outputURL = nil
            outputRemoteURL = nil
            outputSuggestedFileName = nil
            outputDownloadExpiresAt = nil
            outputFileSize = nil
            resultAspectRatio = nil
            latestStatus = nil
            creditsUsed = nil
            projectId = nil
            runId = nil
            estimatedCredits = nil
            phase = .creatingUpload
            progress = 0.08
            statusMessage = "Creating secure upload URLs..."
            let shouldDeclareDimensions = selectedVideo.metadata.inferredAspectRatio != aspectRatio

            let srtForRender = autoTranscribe ? nil : selectedSRT
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
                srt: srtForRender.map {
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

            if let srtForRender, let srtUpload = upload.srt {
                phase = .uploadingSRT
                progress = 0.28
                statusMessage = "Uploading \(srtForRender.fileName)..."
                try await client.uploadFile(
                    fileURL: srtForRender.url,
                    uploadURL: srtUpload.uploadUrl,
                    contentType: "text/plain",
                    fileSize: srtForRender.fileSize
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
            resultAspectRatio = aspectRatio
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

    func cacheCurrentOutput() {
        guard outputURL == nil, outputRemoteURL != nil, outputCacheTask == nil else { return }
        outputCacheTask = Task { @MainActor [weak self] in
            await self?.downloadCurrentOutput(showAlertOnFailure: false)
        }
    }

    func downloadCurrentOutput() async -> URL? {
        if let outputURL {
            return outputURL
        }

        if let outputCacheTask {
            let cachedURL = await outputCacheTask.value
            self.outputCacheTask = nil
            if let cachedURL {
                return cachedURL
            }
        }

        return await downloadCurrentOutput(showAlertOnFailure: true)
    }

    private func downloadCurrentOutput(showAlertOnFailure: Bool) async -> URL? {
        if let outputURL {
            return outputURL
        }
        guard let outputRemoteURL else {
            if showAlertOnFailure {
                alert = AppMessage(title: "Download unavailable", message: "The rendered MP4 is not ready yet.")
            }
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
            outputCacheTask = nil
            phase = .completed
            statusMessage = "Downloaded."
            return localURL
        } catch {
            outputCacheTask = nil
            phase = .completed
            if showAlertOnFailure {
                alert = AppMessage(title: "Could not download MP4", message: error.localizedDescription)
            }
            return nil
        }
    }

    func downloadHistoryItem(_ item: LocalUploadQueueItem) async -> URL? {
        guard await openHistoryItem(item) else { return nil }
        return await downloadCurrentOutput()
    }

    func openHistoryItem(_ item: LocalUploadQueueItem) async -> Bool {
        guard item.isDownloadAvailable else {
            alert = AppMessage(title: "Download expired", message: "This history item is past the 58-minute download window.")
            return false
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            alert = AppMessage(title: "API key required", message: "Enter a Subclip API key to refresh this download.")
            return false
        }

        do {
            let info = try await client.downloadInfo(apiKey: trimmedKey, projectId: item.projectId)
            let fileName = info.fileName ?? item.outputFileName ?? "captioned-video.mp4"
            outputCacheTask?.cancel()
            outputCacheTask = nil
            outputURL = nil
            outputRemoteURL = info.downloadUrl
            outputSuggestedFileName = fileName
            outputFileSize = info.fileSize
            outputDownloadExpiresAt = downloadExpiryDate(from: info)
            resultAspectRatio = OutputAspectRatio(rawValue: item.aspectRatio) ?? .vertical
            projectId = item.projectId
            phase = .completed
            progress = 1
            statusMessage = "Ready to download."
            creditsUsed = item.creditsUsed
            updateQueueItem(
                projectId: item.projectId,
                status: "Completed",
                outputFileName: fileName,
                outputFileSize: info.fileSize,
                creditsUsed: item.creditsUsed,
                downloadExpiresAt: outputDownloadExpiresAt
            )
            return true
        } catch {
            alert = AppMessage(title: "Could not open history item", message: error.localizedDescription)
            return false
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

    private func defaultSRTFileName() -> String {
        defaultSRTFileName(for: selectedVideo?.fileName ?? "captions.mp4")
    }

    private func defaultSRTFileName(for fileName: String) -> String {
        let base = fileName.replacingOccurrences(
            of: "\\.(mp4|mov|webm|mkv|avi|m4v|mpg|mpeg)$",
            with: "",
            options: .regularExpression
        )
        return "\(base)-captions.srt"
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

    private func quotaSuccessMessage(for quota: QuotaResponse) -> String {
        let balance = quota.aiCredits.balance.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "Unknown"
        return "AI credits available: \(balance)."
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

    nonisolated private static func storedValidationMatches(_ apiKey: String) -> Bool {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return false }
        return UserDefaults.standard.string(forKey: validatedAPIKeyHashKey) == apiKeyHash(trimmedKey)
    }

    nonisolated private static func apiKeyHash(_ apiKey: String) -> String {
        let digest = SHA256.hash(data: Data(apiKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
