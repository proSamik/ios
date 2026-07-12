import BetterAuth
import Foundation

struct SubclipAPIClient {
    var baseURL = URL(string: "https://www.subclip.app")!
    let authClient: BetterAuthClient

    func createUpload(payload: CreateUploadRequest) async throws -> UploadResponse {
        try await jsonRequest(
            path: "/api/v1/dynamic-captions/uploads",
            method: "POST",
            body: payload,
            responseType: UploadResponse.self
        )
    }

    func startJob(payload: StartJobRequest) async throws -> StartJobResponse {
        try await jsonRequest(
            path: "/api/v1/dynamic-captions/jobs",
            method: "POST",
            body: payload,
            responseType: StartJobResponse.self
        )
    }

    func jobStatus(projectId: String) async throws -> JobStatusResponse {
        try await jsonRequest(
            path: "/api/v1/dynamic-captions/jobs/\(projectId)",
            method: "GET",
            body: Optional<EmptyBody>.none,
            responseType: JobStatusResponse.self
        )
    }

    func downloadInfo(projectId: String) async throws -> DownloadInfoResponse {
        try await jsonRequest(
            path: "/api/v1/dynamic-captions/jobs/\(projectId)/download",
            method: "GET",
            body: Optional<EmptyBody>.none,
            responseType: DownloadInfoResponse.self
        )
    }

    func previewInfo(projectId: String) async throws -> DownloadInfoResponse {
        try await jsonRequest(
            path: "/api/v1/dynamic-captions/jobs/\(projectId)/download?purpose=preview",
            method: "GET",
            body: Optional<EmptyBody>.none,
            responseType: DownloadInfoResponse.self
        )
    }

    func quota() async throws -> QuotaResponse {
        try await jsonRequest(
            path: "/api/v1/quota",
            method: "GET",
            body: Optional<EmptyBody>.none,
            responseType: QuotaResponse.self
        )
    }

    func billingAccess() async throws -> BillingAccessResponse {
        try await jsonRequest(
            path: "/api/v1/billing/access",
            method: "GET",
            body: Optional<EmptyBody>.none,
            responseType: BillingAccessResponse.self
        )
    }

    func bootstrapMobileAccount(grantWelcomeCredits: Bool) async throws -> MobileBootstrapResponse {
        try await jsonRequest(
            path: "/api/v1/mobile/bootstrap",
            method: "POST",
            body: MobileBootstrapRequest(grantWelcomeCredits: grantWelcomeCredits),
            responseType: MobileBootstrapResponse.self
        )
    }

    func uploadFile(
        fileURL: URL,
        uploadURL: URL,
        contentType: String,
        fileSize: Int64,
        progress: @MainActor @escaping @Sendable (Double) -> Void
    ) async throws {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")
        request.timeoutInterval = 60 * 60

        try await FastMediaUploader.upload(fileURL: fileURL, request: request, progress: progress)
    }

    func downloadFile(
        from remoteURL: URL,
        suggestedFileName: String,
        projectId: String? = nil,
        progress: @MainActor @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        let destination = try outputFileURL(suggestedFileName: suggestedFileName, projectId: projectId)
        return try await FastMediaDownloader.download(
            from: remoteURL,
            to: destination,
            progress: progress
        )
    }

    func cachedOutputFileURL(
        suggestedFileName: String,
        projectId: String? = nil,
        expectedSize: Int64?,
        cacheExpiresAt: Date? = nil
    ) -> URL? {
        if let cacheExpiresAt, Date() >= cacheExpiresAt {
            return nil
        }
        do {
            let destination = try outputFileURL(suggestedFileName: suggestedFileName, projectId: projectId)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            guard let sizeNumber = attributes[.size] as? NSNumber else { return nil }
            let size = sizeNumber.int64Value
            guard size > 0 else { return nil }
            if let expectedSize, expectedSize > 0, size != expectedSize { return nil }
            return destination
        } catch {
            return nil
        }
    }

    func outputFileURL(
        suggestedFileName: String,
        projectId: String?
    ) throws -> URL {
        let directory = try outputDirectory()
        let safeFileName = sanitizedFileName(suggestedFileName, fallback: "captioned-video.mp4")
        let safeProjectId = sanitizedFileName(projectId ?? "", fallback: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = safeProjectId.isEmpty ? safeFileName : "\(safeProjectId)_\(safeFileName)"
        return directory.appendingPathComponent(fileName)
    }

    private func outputDirectory() throws -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = base.appendingPathComponent("ViralCaptionsDownloads", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func jsonRequest<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body?,
        responseType: Response.Type
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw SubclipAPIError(message: "The Subclip request URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        guard let cookie = authClient.getCookie() else {
            throw SubclipAPIError(message: "Your Subclip session expired. Sign in again.", code: "session_expired", statusCode: 401)
        }
        request.setValue("\(cookie.name)=\(cookie.value)", forHTTPHeaderField: "Cookie")
        request.setValue("subclip://", forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 90

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SubclipAPIError(message: "No HTTP response was received.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let apiError = try? JSONDecoder().decode(APIErrorPayload.self, from: data)
            throw SubclipAPIError(
                message: apiError?.message ?? apiError?.error ?? "Request failed with HTTP \(http.statusCode).",
                code: apiError?.error,
                statusCode: http.statusCode
            )
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw SubclipAPIError(message: "Subclip returned an unexpected response: \(error.localizedDescription)")
        }
    }
}

struct EmptyBody: Encodable {}

struct SubclipAPIError: LocalizedError {
    let message: String
    var code: String?
    var statusCode: Int?

    var errorDescription: String? {
        if let code {
            return "\(message) (\(code))"
        }
        return message
    }
}

private struct APIErrorPayload: Decodable {
    let error: String?
    let message: String?
}

struct CreateUploadRequest: Encodable {
    struct Asset: Encodable {
        let fileName: String
        let contentType: String
        let fileSize: Int64
        var durationSeconds: Double?
        var width: Int?
        var height: Int?
    }

    struct SRTAsset: Encodable {
        let fileName: String
        let contentType: String
        let fileSize: Int64
    }

    let projectName: String
    let video: Asset
    var srt: SRTAsset?
}

struct UploadResponse: Decodable {
    struct UploadSlot: Decodable {
        let uploadUrl: URL
        let objectKey: String
        let fileName: String?
        let contentType: String?
        let expiresIn: Int?
    }

    let projectId: String
    let uploadExpiresIn: Int
    let video: UploadSlot
    let srt: UploadSlot?
}

struct StartJobRequest: Encodable {
    let projectId: String
    let language: String
    let templateId: String
    let aspectRatio: String
    let placement: String?
    let faceTrack: Bool?
    let outputFileName: String?
}

struct StartJobResponse: Decodable {
    let projectId: String
    let status: String
    let runId: String?
    let estimatedCredits: Double?
    let statusUrl: String?
    let downloadUrl: String?
}

struct JobStatusResponse: Decodable, Equatable {
    let projectId: String
    let status: String
    let progress: Double?
    let outputReady: Bool
    let creditsUsed: Double?
    let errorMessage: String?
    let latestJobId: String?
    let renderId: String?
    let createdAt: String?
    let updatedAt: String?
    let expiresIn: String?

    var normalizedStatus: String {
        status.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct DownloadInfoResponse: Decodable {
    let projectId: String
    let downloadUrl: URL
    let expiresAt: String?
    let expiresIn: Int?
    let mediaType: String?
    let contentType: String?
    let fileSize: Int64?
    let fileName: String?
}

struct QuotaResponse: Decodable, Equatable {
    struct Storage: Decodable, Equatable {
        let applies: Bool
        let usedBytes: Int64?
        let remainingBytes: Int64?
        let limitBytes: Int64?
        let message: String?
    }

    struct UploadCheck: Decodable, Equatable {
        let fileSizeBytes: Int64?
        let allowed: Bool
    }

    struct AICredits: Decodable, Equatable {
        let allowed: Bool
        let balance: Double?
        let estimatedCredits: Double?
    }

    let storage: Storage?
    let uploadCheck: UploadCheck?
    let aiCredits: AICredits
}

struct BillingAccessResponse: Decodable, Equatable {
    let status: String
    let source: String
    let hasPolarAccess: Bool
    let hasRevenueCatAccess: Bool
    let shouldShowRevenueCat: Bool
    let hasPreviousPass: Bool
    let revenueCatExpiresAt: String?
    let revenueCatLifetime: Bool?
    let creditsRollover: Bool?
    let message: String?
}

private struct MobileBootstrapRequest: Encodable {
    let grantWelcomeCredits: Bool
}

struct MobileBootstrapResponse: Decodable, Equatable {
    let success: Bool
    let welcomeCredits: Double
    let welcomeCreditsGranted: Bool
}
