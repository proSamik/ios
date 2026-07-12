import Foundation

enum FastMediaDownloader {
    static func download(
        from remoteURL: URL,
        to destinationURL: URL,
        progress: @MainActor @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        let operation = DownloadOperation(
            remoteURL: remoteURL,
            destinationURL: destinationURL,
            progress: progress
        )

        return try await withTaskCancellationHandler {
            try await operation.start()
        } onCancel: {
            operation.cancel()
        }
    }
}

private final class DownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let remoteURL: URL
    private let destinationURL: URL
    private let progressHandler: @MainActor @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var didMoveFile = false
    private var lastProgressUpdate = Date.distantPast

    init(
        remoteURL: URL,
        destinationURL: URL,
        progress: @MainActor @escaping @Sendable (Double?) -> Void
    ) {
        self.remoteURL = remoteURL
        self.destinationURL = destinationURL
        self.progressHandler = progress
    }

    func start() async throws -> URL {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 90
            configuration.timeoutIntervalForResource = 10 * 60
            configuration.waitsForConnectivity = true
            configuration.allowsConstrainedNetworkAccess = true
            configuration.allowsExpensiveNetworkAccess = true
            configuration.httpMaximumConnectionsPerHost = 4
            configuration.networkServiceType = .responsiveData

            let queue = OperationQueue()
            queue.name = "app.subclip.media-download"
            queue.qualityOfService = .userInitiated
            queue.maxConcurrentOperationCount = 1

            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = 90
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("video/mp4,video/*;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")

            let task = session.downloadTask(with: request)
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
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastProgressUpdate) >= 0.1 || totalBytesWritten == totalBytesExpectedToWrite else { return }
        lastProgressUpdate = now
        let value: Double? = totalBytesExpectedToWrite > 0
            ? min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
            : nil
        Task { @MainActor in self.progressHandler(value) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                throw URLError(.badServerResponse)
            }
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: location, to: destinationURL)
            didMoveFile = true
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
        } else if didMoveFile {
            Task { @MainActor in self.progressHandler(1) }
            finish(.success(destinationURL))
        } else {
            finish(.failure(CocoaError(.fileReadUnknown)))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
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
