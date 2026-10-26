import Foundation

/// Fetches the signed `sr` installer package for `CLIHelpWindowController`. A protocol so the
/// window's tests can fake it; `URLSessionCLIPackageDownloader` is the one real conformer.
protocol CLIPackageDownloading: Sendable {
    /// Downloads `url` to a file under `FileManager.default.temporaryDirectory` and returns
    /// that location; the caller moves it to its final, user-visible place.
    /// `progressHandler` gets a `0...1` fraction as bytes arrive, on an arbitrary thread; a
    /// response with no `Content-Length` never calls it. Cancelling the calling `Task` cancels
    /// the transfer and throws `URLError(.cancelled)`.
    func download(from url: URL, progressHandler: @escaping @Sendable (Double) -> Void) async throws -> URL
}

enum CLIPackageDownloadError: LocalizedError {
    case badResponse(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .badResponse(let statusCode):
            return "The server answered \(statusCode) for \(CLIHelpWindowController.installerPackageFilename)."
        }
    }
}

/// A plain `URLSession` download. One delegate per download, so the struct itself holds no state.
struct URLSessionCLIPackageDownloader: CLIPackageDownloading {
    func download(from url: URL, progressHandler: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = DownloadDelegate(progressHandler: progressHandler)
        // The session retains its delegate until invalidated; `finish` invalidates it.
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        // Cancelling the wrapping Task does not touch the in-flight transfer by itself.
        // Cancelling the URLSession task resumes the continuation with `URLError(.cancelled)`
        // through `didCompleteWithError`, so there is one failure path.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(continuation: continuation, session: session)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let progressHandler: @Sendable (Double) -> Void
        // Delegate callbacks arrive serialized on the session's private queue; `start` runs
        // before the task resumes. `finish` clears the continuation, so it resumes only once.
        private var continuation: CheckedContinuation<URL, Error>?
        private var session: URLSession?

        init(progressHandler: @escaping @Sendable (Double) -> Void) {
            self.progressHandler = progressHandler
        }

        func start(continuation: CheckedContinuation<URL, Error>, session: URLSession) {
            self.continuation = continuation
            self.session = session
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            finish(.failure(error))
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            progressHandler(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
        ) {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                finish(.failure(CLIPackageDownloadError.badResponse(statusCode: http.statusCode)))
                return
            }
            // `location` is deleted the instant this method returns; move it somewhere the
            // caller can still read.
            let stable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.moveItem(at: location, to: stable)
                finish(.success(stable))
            } catch {
                finish(.failure(error))
            }
        }

        private func finish(_ result: Result<URL, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
            session?.finishTasksAndInvalidate()
            session = nil
        }
    }
}
