import Foundation

/// Job 276 (interim in-app download, ahead of a public Sparkle feed): fetches a GitHub release
/// ASSET's actual bytes — `GET /repos/.../releases/assets/{id}` with
/// `Accept: application/octet-stream` — as opposed to `GitHubUpdateFeed`, which only ever reads
/// the releases LIST. A protocol, not a bare function, so `AppDelegate`'s download flow is
/// testable the same way `UpdateFeed`/`UpdateTokenProvider` already are: a fake conformer in
/// tests, exactly one real conformer (`GitHubAssetDownloader`) in production. Deliberately NOT
/// `@MainActor` — `GitHubAssetDownloader`'s `URLSessionDownloadDelegate` callbacks arrive on an
/// arbitrary session queue, and a caller awaiting this from `@MainActor` (as `AppDelegate`
/// does) gets the same result either way since a nonisolated `async` function is callable from
/// any isolation domain.
/// Job 313C: `: Sendable` — `CLIHelpWindowController` stores its `downloader` as an
/// existential (`any UpdateAssetDownloading`) rather than calling a freshly-constructed
/// concrete `GitHubAssetDownloader()` inline, so the compiler needs the PROTOCOL itself to
/// promise Sendable before it will let a `@MainActor`-isolated stored property cross into
/// this nonisolated `async` call — matching `UpdateFeed`'s own `: Sendable` conformance above
/// for the identical reason.
protocol UpdateAssetDownloading: Sendable {
    /// Downloads the asset to a location under `FileManager.default.temporaryDirectory` and
    /// returns that location — the caller (`UpdateDownloadDestination`) owns moving it to its
    /// final, user-visible name. `progressHandler` is hopped onto the main actor before it's
    /// called (see `GitHubAssetDownloader`'s `didWriteData`) with a `0...1` fraction as bytes
    /// arrive; a response with no `Content-Length` never calls it at all, which is what lets
    /// the caller fall back to an indeterminate spinner.
    func download(asset: UpdateFeedAsset, progressHandler: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// GitHub answers the assets endpoint with a 302 to a presigned, self-authenticating storage
/// URL (a different host than `api.github.com`). Forwarding this app's own bearer token onto
/// that redirected request would attach a second, conflicting auth mechanism to a URL that
/// already carries one in its query string — this type strips `Authorization` before letting
/// `URLSession` follow any redirect that lands on a different host than the one it was sent to.
/// This is the documented shape of GitHub's own release-asset download flow; this worker has no
/// network access to attach a fresh citation for it (see the job report's LESSONS) — flagged
/// here rather than asserted as sourced, same convention `UpdateChecker.swift` already uses for
/// its own uncited claims.
final class GitHubAssetDownloader: NSObject, UpdateAssetDownloading, URLSessionDownloadDelegate, @unchecked Sendable {
    private let session: URLSession
    private let tokenProvider: any UpdateTokenProvider

    /// One delegate instance per in-flight download — `URLSessionDownloadDelegate` callbacks
    /// arrive on an arbitrary session queue, not necessarily the main actor, so this type is
    /// deliberately NOT `@MainActor`; it only ever hops to the main actor to call the
    /// `@MainActor` progress handler and to resume the continuation.
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: (@Sendable (Double) -> Void)?
    private var requestHost: String?
    /// Job 280: `URLSession` retains its delegate, and this delegate (`self`) is `ownedSession`'s
    /// only strong reference back to itself — without invalidating it, every download leaks both
    /// the session and this downloader. Stored so `finish(_:)` (the one place the download is
    /// known to be over) can invalidate it; delegate callbacks all arrive serialized on the same
    /// private queue `delegateQueue: nil` creates below, so `finish(_:)`'s existing
    /// `guard let continuation` already prevents this from running more than once per download —
    /// no separate lock needed to keep the invalidate call from racing a second delegate callback.
    private var ownedSession: URLSession?

    init(session: URLSession = .shared, tokenProvider: any UpdateTokenProvider = KeychainUpdateTokenProvider()) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    func download(asset: UpdateFeedAsset, progressHandler: @escaping @Sendable (Double) -> Void) async throws -> URL {
        var request = URLRequest(url: GitHubUpdateFeed.assetDownloadURL(id: asset.id))
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        if let token = tokenProvider.token(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        self.progressHandler = progressHandler
        self.requestHost = request.url?.host

        let ownedSession = URLSession(
            configuration: session.configuration, delegate: self, delegateQueue: nil)
        self.ownedSession = ownedSession
        let downloadTask = ownedSession.downloadTask(with: request)
        // `Task.cancel()` on the caller's side does not, by itself, touch this in-flight
        // `URLSessionDownloadTask` — Swift concurrency cancellation is cooperative and this
        // continuation never checks it. `withTaskCancellationHandler` is what actually wires
        // "the wrapping Task was cancelled" to "cancel the real network request", which then
        // resumes the continuation with a `URLError(.cancelled)` through the normal
        // `didCompleteWithError` path below — one failure path, not two.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                downloadTask.resume()
            }
        } onCancel: {
            downloadTask.cancel()
        }
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.host != requestHost else {
            completionHandler(request)
            return
        }
        var stripped = request
        stripped.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(stripped)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        finish(.failure(error))
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let handler = progressHandler
        Task { @MainActor in handler?(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            switch http.statusCode {
            case 401: finish(.failure(UpdateFeedError.unauthorized))
            case 404: finish(.failure(UpdateFeedError.notFound))
            default: finish(.failure(UpdateFeedError.badResponse))
            }
            return
        }
        // `location` is deleted the instant this method returns (URLSessionDownloadDelegate's
        // documented contract) — move it to a stable temp path the caller can still see once
        // this delegate method has returned.
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
        // After, not before: the task is already complete by the time any path reaches
        // `finish(_:)`, so there is nothing left for `finishTasksAndInvalidate()` to wait out —
        // ordering it after the resume just keeps the caller's result from ever depending on
        // teardown timing.
        ownedSession?.finishTasksAndInvalidate()
        ownedSession = nil
    }
}
