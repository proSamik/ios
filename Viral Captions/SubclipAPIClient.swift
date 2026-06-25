import Foundation

struct SubclipAPIClient {
    var baseURL = URL(string: "https://www.subclip.app")!

    func createUpload(apiKey: String, payload: CreateUploadRequest) async throws -> UploadResponse {
        try await jsonRequest(
            apiKey: apiKey,
            path: "/api/v1/dynamic-captions/uploads",
            method: "POST",
            body: payload,
            responseType: UploadResponse.self
        )
    }

    func startJob(apiKey: String, payload: StartJobRequest) async throws -> StartJobResponse {
        try await jsonRequest(
            apiKey: apiKey,
            path: "/api/v1/dynamic-captions/jobs",
            method: "POST",
            body: payload,
            responseType: StartJobResponse.self
        )
    }

    func jobStatus(apiKey: String, projectId: String) async throws -> JobStatusResponse {
        try await jsonRequest(
            apiKey: apiKey,
            path: "/api/v1/dynamic-captions/jobs/\(projectId)",
            method: "GET",
            body: Optional<EmptyBody>.none,
            responseType: JobStatusResponse.self
        )
    }

    func downloadInfo(apiKey: String, projectId: String) async throws -> DownloadInfoResponse {
        try await jsonRequest(
            apiKey: apiKey,
            path: "/api/v1/dynamic-captions/jobs/\(projectId)/download",
            method: "GET",
            body: Optional<EmptyBody>.none,
            responseType: DownloadInfoResponse.self
        )
    }

    func quota(apiKey: String) async throws -> QuotaResponse {
        try await jsonRequest(
            apiKey: apiKey,
            path: "/api/v1/quota",
            method: "GET",
            body: Optional<EmptyBody>.none,
            responseType: QuotaResponse.self
        )
    }

    func uploadFile(fileURL: URL, uploadURL: URL, contentType: String, fileSize: Int64) async throws {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")
        request.timeoutInterval = 60 * 60

        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else {
            throw SubclipAPIError(message: "Upload failed before a server response was received.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SubclipAPIError(message: "Upload failed with HTTP \(http.statusCode).")
        }
    }

    func downloadFile(from remoteURL: URL, suggestedFileName: String) async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: remoteURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SubclipAPIError(message: "Download failed.")
        }

        let directory = try outputDirectory()
        let fileName = sanitizedFileName(suggestedFileName, fallback: "captioned-video.mp4")
        let destination = directory.appendingPathComponent(fileName)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func outputDirectory() throws -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = base.appendingPathComponent("Viral Captions", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func jsonRequest<Body: Encodable, Response: Decodable>(
        apiKey: String,
        path: String,
        method: String,
        body: Body?,
        responseType: Response.Type
    ) async throws -> Response {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
