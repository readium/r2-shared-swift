//
//  Copyright 2021 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import UIKit

/// An HTTP client performs HTTP requests.
///
/// You may provide a custom implementation, or use the `DefaultHTTPClient` one which relies on native APIs.
public protocol HTTPClient: Loggable {

    /// Fetches the resource from the given `request`.
    func fetch(_ request: URLRequestConvertible, completion: @escaping (HTTPResult<HTTPFetchResponse>) -> Void) -> Cancellable

    /// Downloads a resource progressively.
    ///
    /// Useful in the context of streaming media playback.
    ///
    /// - Parameters:
    ///   - request: Request to the downloaded resource.
    ///   - range: If provided, issue a byte range request.
    ///   - receiveResponse: Callback called when receiving the initial response, before consuming its body. You can
    ///     also access it in the completion block after consuming the data.
    ///   - consumeData: Callback called for each chunk of data received. Callers are responsible to accumulate the data
    ///     if needed.
    ///   - completion: Callback called when the download finishes or an error occurs.
    /// - Returns: A `Cancellable` interrupting the download when requested.
    func progressiveDownload(
        _ request: URLRequestConvertible,
        range: Range<UInt64>?,
        receiveResponse: ((HTTPResponse) -> Void)?,
        consumeData: @escaping (_ chunk: Data, _ progress: Double?) -> Void,
        completion: @escaping (HTTPResult<HTTPResponse>) -> Void
    ) -> Cancellable

}

public extension HTTPClient {

    /// Fetches the resource and attempts to decode it with the given `decoder`.
    ///
    /// If the decoder fails, a `malformedResponse` HTTP error is returned.
    func fetch<T>(
        _ request: URLRequestConvertible,
        decoder: @escaping (HTTPResponse, Data) throws -> T?,
        completion: @escaping (HTTPResult<T>) -> Void
    ) -> Cancellable {
        fetch(request) { response in
            let result = response.flatMap { response, body -> HTTPResult<T> in
                guard let result = try? decoder(response, body) else {
                    return .failure(HTTPError(kind: .malformedResponse))
                }
                return .success(result)
            }
            completion(result)
        }
    }

    /// Fetches the resource as a JSON object.
    func fetchJSON(_ request: URLRequestConvertible, completion: @escaping (HTTPResult<[String: Any]>) -> Void) -> Cancellable {
        fetch(request,
            decoder: { try JSONSerialization.jsonObject(with: $1) as? [String: Any] },
            completion: completion
        )
    }

    /// Fetches the resource as a `String`.
    func fetchString(_ request: URLRequestConvertible, completion: @escaping (HTTPResult<String>) -> Void) -> Cancellable {
        fetch(request,
            decoder: { response, body in
                let encoding = response.mediaType.encoding ?? .utf8
                return String(data: body, encoding: encoding)
            },
            completion: completion
        )
    }

    /// Fetches the resource as an `UIImage`.
    func fetchImage(_ request: URLRequestConvertible, completion: @escaping (HTTPResult<UIImage>) -> Void) -> Cancellable {
        fetch(request,
            decoder: { UIImage(data: $1) },
            completion: completion
        )
    }

    /// Fetches a resource synchronously.
    func synchronousFetch(_ request: URLRequestConvertible) -> HTTPResult<HTTPFetchResponse> {
        warnIfMainThread()

        var result: HTTPResult<HTTPFetchResponse>!

        let semaphore = DispatchSemaphore(value: 0)
        _ = fetch(request) {
            result = $0
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .distantFuture)

        return result!
    }

}

public typealias HTTPFetchResponse = (response: HTTPResponse, body: Data)

/// Represents a successful HTTP response received from a server.
public struct HTTPResponse {

    /// HTTP response headers, indexed by their name.
    public let headers: [String: String]

    /// Media type sniffed from the `Content-Type` header and response body.
    /// Falls back on `application/octet-stream`.
    public let mediaType: MediaType

    public init(headers: [String: String], mediaType: MediaType) {
        self.headers = headers
        self.mediaType = mediaType
    }

    public init(response: HTTPURLResponse, body: Data? = nil) {
        var headers: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            if let ks = k as? String, let vs = v as? String {
                headers[ks] = vs
            }
        }

        self.init(
            headers: headers,
            mediaType: response.sniffMediaType { body ?? Data() } ?? .binary
        )
    }

    /// Finds the value of the first header matching the given name.
    ///
    /// In keeping with the HTTP RFC, HTTP header field names are case-insensitive.
    public func valueForHeader(_ name: String) -> String? {
        let name = name.lowercased()
        for (n, v) in headers {
            if n.lowercased() == name {
                return v
            }
        }
        return nil
    }

    /// Indicates whether this server supports byte range requests.
    public var acceptsByteRanges: Bool {
        return valueForHeader("Accept-Ranges")?.lowercased() == "bytes"
            || valueForHeader("Content-Range")?.lowercased().hasPrefix("bytes") == true
    }

    /// The expected content length for this response, when known.
    /// Warning: For byte range requests, this will
    public var contentLength: Int64? {
        valueForHeader("Content-Length")
            .flatMap { Int64($0) }
            .takeIf { $0 >= 0 }
    }

}
