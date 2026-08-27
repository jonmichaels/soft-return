import Foundation
import Testing
@testable import SoftReturn

/// Job 276: `GitHubAssetDownloader` end to end against a stubbed `URLProtocol`, same technique
/// `UpdateCheckerTests` already uses for `GitHubUpdateFeed` — no live network reaches this file.

private struct FakeTokenProvider: UpdateTokenProvider {
    let value: String?
    func token() -> String? { value }
}

@Test func downloadAttachesTheBearerTokenExactlyOnce() async throws {
    AssetHeaderRecordingURLProtocol.authorizationHeaderCounts = [:]
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AssetHeaderRecordingURLProtocol.self]
    let session = URLSession(configuration: config)

    let downloader = GitHubAssetDownloader(session: session, tokenProvider: FakeTokenProvider(value: "abc123"))
    let asset = UpdateFeedAsset(id: 7, name: "Soft-Return-4.0.0b20.dmg", size: 4)
    let tempURL = try await downloader.download(asset: asset) { _ in }
    defer { try? FileManager.default.removeItem(at: tempURL) }

    #expect(AssetHeaderRecordingURLProtocol.authorizationHeaderCounts["Bearer abc123"] == 1)
}

@Test func downloadSendsNoAuthorizationHeaderWhenThereIsNoToken() async throws {
    AssetHeaderRecordingURLProtocol.authorizationHeaderCounts = [:]
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AssetHeaderRecordingURLProtocol.self]
    let session = URLSession(configuration: config)

    let downloader = GitHubAssetDownloader(session: session, tokenProvider: FakeTokenProvider(value: nil))
    let asset = UpdateFeedAsset(id: 7, name: "Soft-Return-4.0.0b20.dmg", size: 4)
    let tempURL = try await downloader.download(asset: asset) { _ in }
    defer { try? FileManager.default.removeItem(at: tempURL) }

    #expect(AssetHeaderRecordingURLProtocol.authorizationHeaderCounts.isEmpty)
}

@Test func downloadThrowsUnauthorizedOnHTTP401() async {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AssetUnauthorizedURLProtocol.self]
    let session = URLSession(configuration: config)

    let downloader = GitHubAssetDownloader(session: session, tokenProvider: FakeTokenProvider(value: "expired"))
    let asset = UpdateFeedAsset(id: 7, name: "Soft-Return-4.0.0b20.dmg", size: 4)

    await #expect(throws: UpdateFeedError.unauthorized) {
        _ = try await downloader.download(asset: asset) { _ in }
    }
}

@Test func downloadThrowsNotFoundOnHTTP404() async {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AssetNotFoundURLProtocol.self]
    let session = URLSession(configuration: config)

    let downloader = GitHubAssetDownloader(session: session, tokenProvider: FakeTokenProvider(value: nil))
    let asset = UpdateFeedAsset(id: 7, name: "Soft-Return-4.0.0b20.dmg", size: 4)

    await #expect(throws: UpdateFeedError.notFound) {
        _ = try await downloader.download(asset: asset) { _ in }
    }
}

/// Answers every request with 200 + a few bytes, and counts how many times each
/// `Authorization` header VALUE was seen — "exactly once" (the brief's own phrasing) is a count
/// assertion, not just a presence one, since the redirect-stripping logic in
/// `GitHubAssetDownloader` could in principle re-attach it on a second, same-host leg.
private final class AssetHeaderRecordingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var authorizationHeaderCounts: [String: Int] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        if let header = request.value(forHTTPHeaderField: "Authorization") {
            Self.authorizationHeaderCounts[header, default: 0] += 1
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("dmg-bytes".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class AssetUnauthorizedURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class AssetNotFoundURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}
