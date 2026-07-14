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

    let auth: BetterAuthStore
    @Published var selectedVideo: SelectedVideo?
    @Published var selectedSRT: SelectedSRT?
    @Published var isImportingVideo = false
    @Published var videoImportProgress: Double = 0
    @Published var selectedTemplateId = "bold-clean"
    @Published var selectedLanguage = "auto"
    @Published var aspectRatio: OutputAspectRatio = .vertical
    @Published var placement: CaptionPlacement = .none
    @Published var faceTrack = true
    @Published var cloudTranscribe = false
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
    @Published var isOutputCaching = false
    @Published var outputDownloadProgress: Double?
    @Published var lowCreditsPaywallRequestID: UUID?
    @Published var passRequiredPaywallRequestID: UUID?
    @Published var isOpeningHistoryPreview = false

    private let client: SubclipAPIClient
    private let localOutputCacheDuration: TimeInterval = 3600
    private var authObservation: AnyCancellable?
    private var pollTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var outputCacheTask: Task<URL?, Never>?
    private var importedVideoURL: URL?
    private var activeLocalUserID: String?
    init() {
        let auth = BetterAuthStore()
        self.auth = auth
        self.client = SubclipAPIClient(authClient: auth.client)
        LocalUploadQueueStore.discardLegacyUnscopedHistory()
        self.uploadQueue = []
        self.authObservation = auth.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        Task { await auth.restoreSession() }
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
        auth.isAuthenticated
            && selectedVideo != nil
            && !isRendering
            && !isTranscribing
            && !isCheckingQuota
    }

    /// Mirrors the server's Dynamic Captions credit calculation so the cost is
    /// visible before the upload starts. The server remains authoritative.
    var previewEstimatedCredits: Double? {
        guard let durationSeconds = selectedVideo?.metadata.durationSeconds else { return nil }
        let minutes = max(1.0 / 60.0, max(0, durationSeconds) / 60.0)
        let renderCredits = minutes
        // With Cloud Transcribe enabled and no supplied transcript, the server
        // performs transcription. Otherwise export prepares a missing transcript
        // locally before uploading the render request.
        let transcriptionCredits = cloudTranscribe && selectedSRT == nil ? minutes : 0.0
        let analysisCredits = 1.0
        let faceTrackCredits = effectiveFaceTrack ? max(1.0, minutes) : 0
        let total = max(2.0, renderCredits + transcriptionCredits + analysisCredits + faceTrackCredits)
        return (total * 100).rounded() / 100
    }

    var needsAuthentication: Bool {
        !auth.isAuthenticated
    }

    var selectedTemplate: CaptionTemplate {
        CaptionTemplate.all.first(where: { $0.id == selectedTemplateId }) ?? CaptionTemplate.all[0]
    }

    var resultPreviewURL: URL? {
        outputURL ?? outputRemoteURL
    }

    var hasResult: Bool {
        outputURL != nil || outputRemoteURL != nil
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

    func setCloudTranscribe(_ isEnabled: Bool) {
        cloudTranscribe = isEnabled
    }

    func refreshQuota() async {
        guard auth.isAuthenticated else { return }
        isCheckingQuota = true
        do {
            let quota = try await client.quota()
            quotaInfo = quota
        } catch {
            // Quota refresh runs in the background and must never interrupt an
            // upload/render with a transient network alert. Keep the last known
            // value; the actual job endpoint remains the source of truth.
            print("Background quota refresh failed: \(error.localizedDescription)")
        }
        isCheckingQuota = false
    }

    func billingAccess() async throws -> BillingAccessResponse {
        try await client.billingAccess()
    }

    func bootstrapMobileAccount() async {
        guard auth.isAuthenticated else { return }
        do {
            let shouldGrant = auth.shouldClaimIOSWelcomeCredits
            let response = try await client.bootstrapMobileAccount(grantWelcomeCredits: shouldGrant)
            if response.success && shouldGrant {
                auth.markIOSWelcomeCreditsClaimed()
            }
        } catch {
            // Provisioning is retried the next time the authenticated view appears.
            print("Mobile account bootstrap failed: \(error.localizedDescription)")
        }
    }

    func importVideo(from url: URL, alreadyLocal: Bool = false) {
        Task {
            await setVideo(from: url, alreadyLocal: alreadyLocal)
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
        Task {
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try String(contentsOf: selectedSRT.url, encoding: .utf8)
                }.value
                srtDraft = text
                isSRTEditorPresented = true
            } catch {
                alert = AppMessage(title: "Could not open SRT", message: error.localizedDescription)
            }
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
        outputDownloadProgress = nil
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
            guard let self else { return }
            await self.refreshQuota()
            guard !Task.isCancelled else { return }

            // Billing access is the authoritative combined Polar/RevenueCat
            // balance. Prefer it over a previously cached quota response so an
            // insufficient-credit paywall appears before any media is uploaded.
            let billingAccess = try? await self.billingAccess()
            if let required = self.previewEstimatedCredits,
               let available = billingAccess?.creditsBalance ?? self.quotaInfo?.aiCredits.balance,
               available + 0.0001 < required {
                self.phase = .idle
                self.progress = 0
                self.statusMessage = "More AI credits are required before rendering."
                self.alert = AppMessage(
                    title: "Not enough AI credits",
                    message: "This preview requires \(required.formatted(.number.precision(.fractionLength(0...2)))) credits, but you have \(available.formatted(.number.precision(.fractionLength(0...2)))). Choose a pass to continue."
                )
                self.lowCreditsPaywallRequestID = UUID()
                return
            }

            await self.runRender()
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
        persistUploadQueue()
    }

    func pruneUploadQueue(at date: Date = Date()) {
        let retained = uploadQueue.filter { $0.shouldRemainInHistory(at: date) }
        guard retained != uploadQueue else { return }
        uploadQueue = retained
        persistUploadQueue()
    }

    func reconcileUploadQueue(at date: Date = Date()) async {
        guard auth.isAuthenticated else { return }
        pruneUploadQueue(at: date)

        // Reconcile uncached local history with the server so a stale local
        // "Completed" label can never keep a failed or expired render visible.
        for item in uploadQueue where !item.isCachedOutputStillAvailable {
            do {
                let status = try await client.jobStatus(projectId: item.projectId)
                let normalized = status.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if normalized == "failed"
                    || normalized == "canceled"
                    || normalized == "cancelled"
                    || normalized == "awaiting_upload"
                    || normalized == "awaiting upload" {
                    removeQueueItem(projectId: item.projectId)
                } else if status.outputReady {
                    updateQueueItem(projectId: item.projectId, status: "Completed")
                } else if date.timeIntervalSince(item.createdAt) >= LocalUploadQueueItem.incompleteRetentionDuration {
                    removeQueueItem(projectId: item.projectId)
                } else {
                    updateQueueItem(projectId: item.projectId, status: status.normalizedStatus)
                }
            } catch let error as SubclipAPIError
                where error.code == "project_not_found"
                    && date.timeIntervalSince(item.createdAt) >= LocalUploadQueueItem.incompleteRetentionDuration {
                removeQueueItem(projectId: item.projectId)
            } catch {
                // Keep history during transient network/server failures. It will
                // be reconciled again on the next account activation or tap.
            }
        }
    }

    func activateLocalAccount(_ userID: String?) {
        guard activeLocalUserID != userID else { return }
        releaseVideoScope()
        selectedVideo = nil
        removeSRT()
        importedVideoURL = nil
        outputFileName = ""
        resetResult()
        activeLocalUserID = userID
        uploadQueue = userID.map { LocalUploadQueueStore.load(userID: $0) } ?? []
        pruneUploadQueue()
    }

    private func setVideo(from url: URL, alreadyLocal: Bool) async {
        releaseVideoScope()
        beginVideoImport()

        let didStartScope = alreadyLocal ? false : url.startAccessingSecurityScopedResource()
        var scopeActive = didStartScope
        var copiedURL: URL?
        do {
            let originalFileName = friendlyVideoFileName(for: url)
            let localURL: URL
            if alreadyLocal {
                localURL = url
            } else {
                localURL = try await Task.detached(priority: .userInitiated) {
                    try Self.copyVideoIntoImports(from: url, fallbackFileName: originalFileName)
                }.value
            }
            copiedURL = localURL
            videoImportProgress = alreadyLocal ? 0.62 : 0.45
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
            let (size, text) = try await Task.detached(priority: .userInitiated) {
                let size = try MediaMetadataReader.fileSize(for: url)
                let text = try String(contentsOf: url, encoding: .utf8)
                return (size, text)
            }.value
            selectedSRT = SelectedSRT(
                url: url,
                fileName: sanitizedFileName(url.lastPathComponent, fallback: "captions.srt"),
                fileSize: size,
                securityScoped: didStartScope
            )
            srtDraft = text
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

    private func prepareLocalTranscriptIfNeeded(for video: SelectedVideo) async throws {
        guard selectedSRT == nil else { return }
        guard localTranscriptionSupported else {
            throw SubclipAPIError(message: "Local transcription is not available for the selected language on this device.")
        }

        isTranscribing = true
        transcriptionProgress = 0.02
        transcriptionStatus = "Preparing captions locally"
        defer { isTranscribing = false }

        let transcript = try await LocalSpeechTranscriber.transcribeVideo(
            at: video.url,
            languageCode: selectedLanguage
        ) { [weak self] progress, status in
            self?.transcriptionProgress = progress
            self?.transcriptionStatus = status
        }
        try Task.checkCancellation()
        try await setSRTText(transcript.srtText, fileName: defaultSRTFileName(for: video.fileName))
        transcriptionProgress = 1
        transcriptionStatus = "Transcript ready"
    }

    private func runRender() async {
        guard let selectedVideo else { return }
        guard auth.isAuthenticated else {
            alert = AppMessage(title: "Sign in required", message: "Sign in to your Subclip account to render captions.")
            return
        }

        do {
            if selectedSRT == nil && !cloudTranscribe {
                phase = .readingMedia
                progress = 0.03
                statusMessage = "Transcribing audio locally…"
                try await prepareLocalTranscriptIfNeeded(for: selectedVideo)
            }

            outputCacheTask?.cancel()
            outputCacheTask = nil
            outputURL = nil
            outputRemoteURL = nil
            outputDownloadProgress = nil
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

            let srtForRender = selectedSRT
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

            let upload = try await client.createUpload(payload: uploadPayload)
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
            ) { [weak self] uploadProgress in
                guard let self else { return }
                self.progress = 0.18 + (uploadProgress * 0.10)
                self.statusMessage = "Uploading video… \(Int(uploadProgress * 100))%"
            }

            if let srtForRender, let srtUpload = upload.srt {
                phase = .uploadingSRT
                progress = 0.28
                statusMessage = "Uploading \(srtForRender.fileName)..."
                try await client.uploadFile(
                    fileURL: srtForRender.url,
                    uploadURL: srtUpload.uploadUrl,
                    contentType: "text/plain",
                    fileSize: srtForRender.fileSize
                ) { [weak self] uploadProgress in
                    guard let self else { return }
                    self.progress = 0.28 + (uploadProgress * 0.05)
                    self.statusMessage = "Uploading captions… \(Int(uploadProgress * 100))%"
                }
            }

            phase = .startingJob
            progress = 0.34
            statusMessage = "Starting Subclip render..."
            updateQueueItem(projectId: upload.projectId, status: "Starting render")
            let start = try await client.startJob(
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

            let completeStatus = try await pollUntilReady(projectId: upload.projectId)
            creditsUsed = completeStatus.creditsUsed

            // Preview is intentionally available without an active pass. The
            // protected download endpoint is requested only after Download or
            // Share has revalidated billing access.
            let info = try await previewInfoWhenReady(projectId: upload.projectId)
            outputRemoteURL = info.downloadUrl
            outputSuggestedFileName = info.fileName ?? normalizedOutputFileName() ?? "captioned-video.mp4"
            outputDownloadExpiresAt = downloadExpiryDate(from: info)
            outputFileSize = info.fileSize
            resultAspectRatio = aspectRatio
            phase = .completed
            progress = 1
            statusMessage = "Preview ready."
            updateQueueItem(
                projectId: upload.projectId,
                status: "Completed",
                outputFileName: outputSuggestedFileName,
                outputFileSize: info.fileSize,
                creditsUsed: completeStatus.creditsUsed,
                downloadExpiresAt: outputDownloadExpiresAt
            )
            cacheCurrentOutput()
        } catch is CancellationError {
            phase = .idle
            statusMessage = "Render canceled."
            if let projectId {
                updateQueueItem(projectId: projectId, status: "Canceled")
            }
        } catch {
            await handleRenderError(error, projectId: projectId)
        }
    }

    private func previewInfoWhenReady(projectId: String) async throws -> DownloadInfoResponse {
        for attempt in 0..<5 {
            do {
                return try await client.previewInfo(projectId: projectId)
            } catch let error as SubclipAPIError
                where error.disposition == .processing && attempt < 4 {
                try await Task.sleep(for: .seconds(attempt + 1))
            }
        }
        throw SubclipAPIError(
            message: "The preview is still being finalized. Check the result again shortly.",
            code: "output_not_ready",
            statusCode: 409
        )
    }

    private func handleRenderError(_ error: Error, projectId: String?) async {
        let apiError = error as? SubclipAPIError
        let disposition: SubclipAPIErrorDisposition
        if let apiError {
            disposition = apiError.disposition
        } else if error is URLError {
            disposition = .retryable
        } else {
            disposition = .unknown
        }

        switch disposition {
        case .purchaseRequired:
            phase = .idle
            progress = 0
            statusMessage = "Choose a pass to continue."
            if let projectId { removeQueueItem(projectId: projectId) }
            alert = AppMessage(
                title: "Pass required",
                message: apiError?.message ?? "Choose an active pass to continue."
            )
            passRequiredPaywallRequestID = UUID()

        case .insufficientCredits:
            phase = .idle
            progress = 0
            statusMessage = "More AI credits are required before rendering."
            if let projectId { removeQueueItem(projectId: projectId) }
            alert = AppMessage(
                title: "Not enough AI credits",
                message: apiError?.message ?? "Choose a pass to add AI credits and continue."
            )
            lowCreditsPaywallRequestID = UUID()

        case .authenticationRequired:
            phase = .idle
            progress = 0
            statusMessage = "Sign in again to continue."
            if let projectId { removeQueueItem(projectId: projectId) }
            alert = AppMessage(
                title: "Session expired",
                message: "Your Subclip session expired. Please sign in again."
            )
            await auth.signOut()

        case .processing:
            phase = .idle
            progress = 0
            statusMessage = "Your preview is still processing."
            if let projectId {
                updateQueueItem(projectId: projectId, status: "Processing")
            }
            alert = AppMessage(
                title: "Preview is still processing",
                message: apiError?.message ?? "Subclip is still preparing this result. Check it again shortly."
            )

        case .retryable:
            phase = .idle
            progress = 0
            let terminalRetryCodes = ["billing_unavailable", "render_timeout", "render_capacity"]
            let shouldRestartExport = apiError?.code.map(terminalRetryCodes.contains) ?? false
            statusMessage = shouldRestartExport
                ? "This export can be retried safely."
                : "Connection interrupted. Your project is safe."
            if let projectId {
                if shouldRestartExport {
                    removeQueueItem(projectId: projectId)
                } else {
                    updateQueueItem(projectId: projectId, status: "Check result")
                }
            }
            alert = AppMessage(
                title: "Please try again",
                message: apiError?.message ?? (shouldRestartExport
                    ? "Subclip could not finish this export. Please start it again."
                    : "Subclip is temporarily unavailable. Your project is safe; try again shortly.")
            )

        case .userActionRequired:
            phase = .idle
            progress = 0
            statusMessage = "Update the video or export settings and try again."
            if let projectId { removeQueueItem(projectId: projectId) }
            alert = AppMessage(
                title: "Check your export",
                message: apiError?.message ?? error.localizedDescription
            )

        case .notFound:
            phase = .idle
            progress = 0
            statusMessage = "This project is no longer available."
            if let projectId { removeQueueItem(projectId: projectId) }
            alert = AppMessage(
                title: "Project unavailable",
                message: apiError?.message ?? "This project could not be found. Start a new export."
            )

        case .renderFailed, .unknown:
            phase = .failed
            progress = 0
            statusMessage = "Render failed."
            if let projectId { removeQueueItem(projectId: projectId) }
            alert = AppMessage(
                title: "Render failed",
                message: apiError?.message ?? error.localizedDescription
            )
        }
    }

    func resumePreparedResultAfterPurchase() async {
        guard let projectId else { return }
        for attempt in 0..<6 {
            do {
                let info = try await client.downloadInfo(projectId: projectId)
                outputRemoteURL = info.downloadUrl
                outputSuggestedFileName = info.fileName ?? normalizedOutputFileName() ?? "captioned-video.mp4"
                outputDownloadExpiresAt = downloadExpiryDate(from: info)
                outputFileSize = info.fileSize
                resultAspectRatio = aspectRatio
                phase = .completed
                progress = 1
                statusMessage = "Ready to download."
                updateQueueItem(
                    projectId: projectId,
                    status: "Completed",
                    outputFileName: outputSuggestedFileName,
                    outputFileSize: info.fileSize,
                    creditsUsed: creditsUsed,
                    downloadExpiresAt: outputDownloadExpiresAt
                )
                cacheCurrentOutput()
                return
            } catch let error as SubclipAPIError where error.code == "pass_required" && attempt < 5 {
                try? await Task.sleep(for: .seconds(attempt + 1))
            } catch {
                alert = AppMessage(title: "Could not open result", message: error.localizedDescription)
                return
            }
        }
        alert = AppMessage(
            title: "Pass is still syncing",
            message: "Your purchase succeeded. Please tap Open Result again in a moment."
        )
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
            await self?.downloadCurrentOutput(showAlertOnFailure: false, updatesStatus: false)
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

        return await downloadCurrentOutput(showAlertOnFailure: true, updatesStatus: true)
    }

    private func downloadCurrentOutput(showAlertOnFailure: Bool, updatesStatus: Bool) async -> URL? {
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
            if updatesStatus {
                phase = .downloading
                statusMessage = "Downloading final MP4..."
            } else {
                isOutputCaching = true
            }
            outputDownloadProgress = 0
            let outputFileName = outputSuggestedFileName ?? normalizedOutputFileName() ?? "captioned-video.mp4"
            let cachedItem = projectId.flatMap { queueItem(for: $0) }
            if let projectId,
               let cachedURL = client.cachedOutputFileURL(
                suggestedFileName: outputFileName,
                projectId: cacheProjectID(projectId),
                expectedSize: outputFileSize,
                cacheExpiresAt: cachedItem?.cachedOutputExpiresAt
            ) {
                outputURL = cachedURL
                outputDownloadProgress = 1
                isOutputCaching = false
                if updatesStatus {
                    phase = .completed
                    statusMessage = "Using cached export."
                }
                updateCacheState(
                    for: projectId,
                    outputFileName: outputFileName,
                    outputFileSize: outputFileSize
                )
                return cachedURL
            }

            let localURL = try await client.downloadFile(
                from: outputRemoteURL,
                suggestedFileName: outputFileName,
                projectId: projectId.map(cacheProjectID)
            ) { [weak self] progress in
                self?.outputDownloadProgress = progress
            }
            outputURL = localURL
            outputDownloadProgress = 1
            outputCacheTask = nil
            isOutputCaching = false
            if let projectId {
                markOutputCached(for: projectId, outputFileName: outputFileName, outputFileSize: outputFileSize)
            }
            if updatesStatus {
                phase = .completed
                statusMessage = "Downloaded."
            }
            return localURL
        } catch {
            outputCacheTask = nil
            isOutputCaching = false
            outputDownloadProgress = nil
            if updatesStatus {
                phase = .completed
            }
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
        guard !isOpeningHistoryPreview else { return false }
        isOpeningHistoryPreview = true
        defer { isOpeningHistoryPreview = false }

        guard item.shouldRemainInHistory() else {
            removeQueueItem(projectId: item.projectId)
            return false
        }

        guard auth.isAuthenticated else {
            alert = AppMessage(title: "Sign in required", message: "Sign in to refresh this download.")
            return false
        }

        outputCacheTask?.cancel()
        outputCacheTask = nil
        outputURL = nil
        outputRemoteURL = nil
        outputDownloadProgress = nil
        projectId = item.projectId
        resultAspectRatio = OutputAspectRatio(rawValue: item.aspectRatio) ?? .vertical
        phase = .completed
        statusMessage = "Loading preview…"

        let cachedFileName = item.outputFileName ?? "captioned-video.mp4"
        if let cachedURL = client.cachedOutputFileURL(
            suggestedFileName: cachedFileName,
            projectId: cacheProjectID(item.projectId),
            expectedSize: item.outputFileSize,
            cacheExpiresAt: item.cachedOutputExpiresAt
        ) {
            outputCacheTask?.cancel()
            outputCacheTask = nil
            outputURL = cachedURL
            outputRemoteURL = nil
            outputSuggestedFileName = cachedFileName
            outputFileSize = item.outputFileSize
            outputDownloadExpiresAt = item.downloadExpiresAt
            resultAspectRatio = OutputAspectRatio(rawValue: item.aspectRatio) ?? .vertical
            projectId = item.projectId
            phase = .completed
            progress = 1
            statusMessage = "Preview ready."
            creditsUsed = item.creditsUsed
            outputDownloadProgress = 1
            updateQueueItem(
                projectId: item.projectId,
                status: "Completed",
                outputFileName: cachedFileName,
                outputFileSize: item.outputFileSize,
                creditsUsed: item.creditsUsed,
                downloadExpiresAt: item.downloadExpiresAt,
                cachedOutputExpiresAt: item.cachedOutputExpiresAt ?? localOutputCacheExpirationDate()
            )
            return true
        }

        do {
            let status = try await client.jobStatus(projectId: item.projectId)
            if status.status.lowercased() == "failed" {
                removeQueueItem(projectId: item.projectId)
                alert = AppMessage(
                    title: "Render removed",
                    message: status.errorMessage ?? "This render failed and was removed from history."
                )
                return false
            }
            guard status.outputReady else {
                if Date().timeIntervalSince(item.createdAt) >= LocalUploadQueueItem.incompleteRetentionDuration {
                    removeQueueItem(projectId: item.projectId)
                    alert = AppMessage(
                        title: "Render expired",
                        message: "This render did not finish within one hour and was removed from history."
                    )
                } else {
                    updateQueueItem(projectId: item.projectId, status: status.normalizedStatus)
                    alert = AppMessage(
                        title: "Result is still processing",
                        message: "Subclip is still preparing this video. Tap Check Result again shortly."
                    )
                }
                phase = .idle
                statusMessage = "Choose a video to begin."
                return false
            }

            let info = try await client.previewInfo(projectId: item.projectId)
            let fileName = info.fileName ?? item.outputFileName ?? "captioned-video.mp4"
            if let cachedURL = client.cachedOutputFileURL(
                suggestedFileName: fileName,
                projectId: cacheProjectID(item.projectId),
                expectedSize: info.fileSize,
                cacheExpiresAt: item.cachedOutputExpiresAt
            ) {
                outputCacheTask?.cancel()
                outputCacheTask = nil
                outputURL = cachedURL
                outputRemoteURL = info.downloadUrl
                outputSuggestedFileName = fileName
                outputFileSize = info.fileSize
                outputDownloadExpiresAt = downloadExpiryDate(from: info)
                resultAspectRatio = OutputAspectRatio(rawValue: item.aspectRatio) ?? .vertical
                projectId = item.projectId
                phase = .completed
                progress = 1
                statusMessage = "Preview ready."
                creditsUsed = item.creditsUsed
                outputDownloadProgress = 1
                updateQueueItem(
                    projectId: item.projectId,
                    status: "Completed",
                    outputFileName: fileName,
                    outputFileSize: info.fileSize,
                    creditsUsed: item.creditsUsed,
                    downloadExpiresAt: downloadExpiryDate(from: info),
                    cachedOutputExpiresAt: item.cachedOutputExpiresAt ?? localOutputCacheExpirationDate()
                )
                return true
            }

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
            statusMessage = "Preview ready."
            creditsUsed = item.creditsUsed
            updateQueueItem(
                projectId: item.projectId,
                status: "Completed",
                outputFileName: fileName,
                outputFileSize: info.fileSize,
                creditsUsed: item.creditsUsed,
                downloadExpiresAt: outputDownloadExpiresAt,
                cachedOutputExpiresAt: item.cachedOutputExpiresAt
            )
            // History previews may begin from the signed remote preview URL,
            // but immediately keep a user-scoped local copy for the same
            // one-hour cache window used by freshly completed renders.
            cacheCurrentOutput()
            return true
        } catch let error as SubclipAPIError where error.code == "output_not_ready" {
            if Date().timeIntervalSince(item.createdAt) >= LocalUploadQueueItem.incompleteRetentionDuration {
                removeQueueItem(projectId: item.projectId)
                alert = AppMessage(
                    title: "Render expired",
                    message: "This render did not finish within one hour and was removed from history."
                )
            } else {
                updateQueueItem(projectId: item.projectId, status: "Processing")
                alert = AppMessage(
                    title: "Result is still processing",
                    message: "Subclip is still preparing this video. Tap Check Result again shortly."
                )
            }
            phase = .idle
            statusMessage = "Choose a video to begin."
            return false
        } catch let error as SubclipAPIError {
            switch error.disposition {
            case .purchaseRequired:
                alert = AppMessage(title: "Pass required", message: error.message)
                passRequiredPaywallRequestID = UUID()
            case .insufficientCredits:
                alert = AppMessage(title: "Not enough AI credits", message: error.message)
                lowCreditsPaywallRequestID = UUID()
            case .authenticationRequired:
                alert = AppMessage(title: "Session expired", message: "Please sign in again to continue.")
                await auth.signOut()
            case .notFound:
                removeQueueItem(projectId: item.projectId)
                alert = AppMessage(title: "Project unavailable", message: error.message)
            case .processing:
                updateQueueItem(projectId: item.projectId, status: "Processing")
                alert = AppMessage(title: "Result is still processing", message: error.message)
            case .retryable:
                alert = AppMessage(title: "Please try again", message: error.message)
            case .userActionRequired, .renderFailed, .unknown:
                alert = AppMessage(title: "Could not open history item", message: error.message)
            }
            return false
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

    private func pollUntilReady(projectId: String) async throws -> JobStatusResponse {
        phase = .polling
        statusMessage = "Rendering on Subclip..."

        for attempt in 0..<720 {
            try Task.checkCancellation()
            let status = try await client.jobStatus(projectId: projectId)
            latestStatus = status
            let serverProgress = max(0, min(100, status.progress ?? 0)) / 100
            progress = min(0.92, 0.36 + (serverProgress * 0.54))
            statusMessage = "\(status.normalizedStatus) \(Int(serverProgress * 100))%"

            if status.outputReady {
                return status
            }

            if status.status.lowercased() == "failed" {
                throw SubclipAPIError(
                    message: status.errorMessage ?? "Subclip render failed.",
                    code: status.errorRetryable == true
                        ? status.errorCode ?? "temporarily_unavailable"
                        : status.errorCode ?? "render_failed"
                )
            }

            let delaySeconds: UInt64 = attempt < 24 ? 5 : 15
            try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
        }

        throw SubclipAPIError(
            message: "The render is taking longer than expected. It is still saved in your history.",
            code: "render_timeout"
        )
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
        persistUploadQueue()
    }

    private func updateQueueItem(
        projectId: String,
        status: String,
        outputFileName: String? = nil,
        outputFileSize: Int64? = nil,
        creditsUsed: Double? = nil,
        downloadExpiresAt: Date? = nil,
        cachedOutputExpiresAt: Date? = nil
    ) {
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedStatus == "failed"
            || normalizedStatus == "canceled"
            || normalizedStatus == "cancelled"
            || normalizedStatus == "awaiting_upload"
            || normalizedStatus == "awaiting upload" {
            removeQueueItem(projectId: projectId)
            return
        }
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
        if let cachedOutputExpiresAt {
            uploadQueue[index].cachedOutputExpiresAt = cachedOutputExpiresAt
        }
        persistUploadQueue()
    }

    private func removeQueueItem(projectId: String) {
        let previousCount = uploadQueue.count
        uploadQueue.removeAll { $0.projectId == projectId }
        if uploadQueue.count != previousCount {
            persistUploadQueue()
        }
    }

    private func localOutputCacheExpirationDate(from baseDate: Date = Date()) -> Date {
        baseDate.addingTimeInterval(localOutputCacheDuration)
    }

    private func markOutputCached(
        for projectId: String,
        outputFileName: String,
        outputFileSize: Int64?
    ) {
        updateQueueItem(
            projectId: projectId,
            status: "Completed",
            outputFileName: outputFileName,
            outputFileSize: outputFileSize,
            cachedOutputExpiresAt: localOutputCacheExpirationDate()
        )
    }

    private func updateCacheState(
        for projectId: String,
        outputFileName: String,
        outputFileSize: Int64?
    ) {
        updateQueueItem(
            projectId: projectId,
            status: "Completed",
            outputFileName: outputFileName,
            outputFileSize: outputFileSize,
            cachedOutputExpiresAt: queueItem(for: projectId)?.cachedOutputExpiresAt
                ?? localOutputCacheExpirationDate()
        )
    }

    private func queueItem(for projectId: String) -> LocalUploadQueueItem? {
        uploadQueue.first(where: { $0.projectId == projectId })
    }

    private func persistUploadQueue() {
        guard let userID = activeLocalUserID else { return }
        LocalUploadQueueStore.save(uploadQueue, userID: userID)
    }

    private func cacheProjectID(_ projectId: String) -> String {
        guard let userID = activeLocalUserID else { return projectId }
        return "\(userID)_\(projectId)"
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
