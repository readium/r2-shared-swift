//
//  Copyright 2021 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// Fetches remote resources with HTTP.
public final class HTTPFetcher: Fetcher, Loggable {
    
    enum HTTPError: Error {
        case invalidURL(String)
        case serverFailure
    }

    /// HTP client used to perform HTTP requests.
    private let client: HTTPClient
    /// Base URL from which relative HREF are served.
    private let baseURL: URL?

    public init(client: HTTPClient, baseURL: URL? = nil) {
        self.client = client
        self.baseURL = baseURL
    }
    
    public let links: [Link] = []
    
    public func get(_ link: Link) -> Resource {
        guard
            let url = link.url(relativeTo: baseURL),
            url.isHTTP
        else {
            log(.error, "Not a valid HTTP URL: \(link.href)")
            return FailureResource(link: link, error: .badRequest(HTTPError.invalidURL(link.href)))
        }
        return HTTPResource(client: client, link: link, url: url)
    }
    
    public func close() { }

    /// HTTPResource provides access to an external URL.
    final class HTTPResource: NSObject, Resource, Loggable, URLSessionDataDelegate {

        let link: Link
        let url: URL

        private let client: HTTPClient

        init(client: HTTPClient, link: Link, url: URL) {
            self.client = client
            self.link = link
            self.url = url
        }

        var length: ResourceResult<UInt64> {
            headResponse.flatMap {
                if let length = $0.contentLength {
                    return .success(UInt64(length))
                } else {
                    return .failure(.unavailable(nil))
                }
            }
        }

        /// Cached HEAD response to get the expected content length and other metadata.
        private lazy var headResponse: ResourceResult<HTTPResponse> = {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"

            return client.synchronousFetch(request)
                .map { $0.response }
                .mapError { ResourceError(httpError: $0) }
        }()

        /// An HTTP resource is always remote.
        var file: URL? { nil }

        func read(range: Range<UInt64>?, consume: @escaping (Data) -> (), completion: @escaping (ResourceResult<()>) -> ()) -> Cancellable {
            client.progressiveDownload(url,
                range: range,
                receiveResponse: nil,
                consumeData: { data, _ in consume(data) },
                completion: { result in
                    completion(result.map { _ in }.mapError { ResourceError(httpError: $0) })
                }
            )
        }

        func close() {}

    }

}

private extension ResourceError {

    // Wraps an `HTTPError` into a `ResourceError`.
    init(httpError: HTTPError) {
        switch httpError.kind {
        case .malformedRequest, .badRequest:
            self = .badRequest(httpError)
        case .timeout, .offline:
            self = .unavailable(httpError)
        case .unauthorized, .forbidden:
            self = .forbidden
        case .notFound:
            self = .notFound
        case .cancelled:
            self = .cancelled
        case .malformedResponse, .clientError, .serverError, .other:
            self = .other(httpError)
        }
    }

}
