import Foundation

enum FastMediaUploader {
    static func upload(
        fileURL: URL,
        request: URLRequest,
        progress: @MainActor @escaping @Sendable (Double) -> Void
    ) async throws {
        let operation = UploadOperation(fileURL: fileURL, request: request, progress: progress)
        try await withTaskCancellationHandler {
            try await operation.start()
        } onCancel: {
            operation.cancel()
        }
    }
}

private final class UploadOperation: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let fileURL: URL
    private let request: URLRequest
    private let progressHandler: @MainActor @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionUploadTask?
    private var lastProgressUpdate = Date.distantPast

    init(
        fileURL: URL,
        request: URLRequest,
        progress: @MainActor @escaping @Sendable (Double) -> Void
    ) {
        self.fileURL = fileURL
        self.request = request
        self.progressHandler = progress
    }

    func start() async throws {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 90
            configuration.timeoutIntervalForResource = 60 * 60
            configuration.waitsForConnectivity = true
            configuration.allowsConstrainedNetworkAccess = true
            configuration.allowsExpensiveNetworkAccess = true
            configuration.networkServiceType = .responsiveData

            let queue = OperationQueue()
            queue.name = "app.subclip.media-upload"
            queue.qualityOfService = .userInitiated
            queue.maxConcurrentOperationCount = 1

            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            let task = session.uploadTask(with: request, fromFile: fileURL)
            lock.lock()
            self.session = session
            self.task = task
            lock.unlock()

            Task { @MainActor in self.progressHandler(0) }
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastProgressUpdate) >= 0.1 || totalBytesSent == totalBytesExpectedToSend else { return }
        lastProgressUpdate = now
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        Task { @MainActor in self.progressHandler(progress) }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }
        guard let response = task.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        Task { @MainActor in self.progressHandler(1) }
        finish(.success(()))
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()

        guard let continuation else { return }
        continuation.resume(with: result)
        session?.finishTasksAndInvalidate()
    }
}
