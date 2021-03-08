//
//  Copyright 2021 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// An implementation of `HTTPClient` using native APIs.
public final class DefaultHTTPClient: NSObject, HTTPClient, Loggable, URLSessionDataDelegate {

    /// Creates a `DefaultHTTPClient` with common configuration.
    ///
    /// - Parameters:
    ///   - cachePolicy: Determines the request caching policy used by HTTP tasks.
    ///   - ephemeral: When true, uses no persistent storage for caches, cookies, or credentials.
    public convenience init(cachePolicy: URLRequest.CachePolicy? = nil, ephemeral: Bool = false) {
        let config: URLSessionConfiguration = ephemeral ? .ephemeral : .default
        if let cachePolicy = cachePolicy {
            config.requestCachePolicy = cachePolicy
        }

        self.init(configuration: config)
    }

    /// Creates a `DefaultHTTPClient` with a custom configuration.
    public init(configuration: URLSessionConfiguration) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    private var session: URLSession!

    deinit {
        session.invalidateAndCancel()
    }

    public func fetch(_ request: URLRequestConvertible, completion: @escaping (HTTPResult<HTTPFetchResponse>) -> ()) -> Cancellable {
        let urlRequest = request.urlRequest
        log(.info, "Fetch (\(urlRequest.httpMethod ?? "GET")) \(request), headers: \(urlRequest.allHTTPHeaderFields ?? [:])")

        let task = FetchTask(
            task: session.dataTask(with: urlRequest),
            completion: completion
        )

        return start(task)
    }

    public func progressiveDownload(_ request: URLRequestConvertible, range: Range<UInt64>?, receiveResponse: ((HTTPResponse) -> Void)?, consumeData: @escaping (Data, Double?) -> Void, completion: @escaping (HTTPResult<HTTPResponse>) -> Void) -> Cancellable {
        var request = request.urlRequest
        if let range = range {
            request.setBytesRange(range)
        }

        log(.info, "Download (progressive) \(request), headers: \(request.allHTTPHeaderFields ?? [:])")

        let task = ProgressiveDownloadTask(
            task: session.dataTask(with: request),
            receiveResponse: receiveResponse,
            consumeData: consumeData,
            completion: completion
        )

        return start(task)
    }


    // MARK: - Task Management

    /// On-going tasks.
    private var tasks: [Task] = []

    private func findTaskIndex(_ task: URLSessionTask) -> Int? {
        let i = tasks.firstIndex(where: { $0.task == task})
        if i == nil {
            log(.error, "Cannot find on-going HTTP task for \(task)")
        }
        return i
    }

    private func start(_ task: Task) -> Cancellable {
        tasks.append(task)
        task.start()
        return task
    }


    // MARK: - URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> ()) {
        guard let i = findTaskIndex(dataTask) else {
            completionHandler(.cancel)
            return
        }
        tasks[i].urlSession(session, didReceive: response, completionHandler: completionHandler)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let i = findTaskIndex(dataTask) else {
            return
        }
        tasks[i].urlSession(session, didReceive: data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let i = findTaskIndex(task) else {
            return
        }
        tasks.remove(at: i)
            .urlSession(session, didCompleteWithError: error)
    }

}


/// Represents an on-going HTTP task.
private protocol Task: Cancellable {
    var task: URLSessionTask { get }

    func urlSession(_ session: URLSession, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> ())
    func urlSession(_ session: URLSession, didReceive data: Data)
    func urlSession(_ session: URLSession, didCompleteWithError error: Error?)
}

private extension Task {

    func start() {
        task.resume()
    }

    func cancel() {
        task.cancel()
    }

}

/// Represents an on-going fetch HTTP task.
private final class FetchTask: Task, Loggable {

    let task: URLSessionTask
    private let completion: (HTTPResult<HTTPFetchResponse>) -> Void

    private var response: HTTPURLResponse? = nil
    /// Body data accumulator.
    private var body = Data()

    init(task: URLSessionDataTask, completion: @escaping (HTTPResult<HTTPFetchResponse>) -> Void) {
        self.task = task
        self.completion = completion
    }

    func urlSession(_ session: URLSession, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> ()) {
        guard !isFinished else {
            completionHandler(.cancel)
            return
        }

        self.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, didReceive data: Data) {
        guard !isFinished else {
            return
        }

        body.append(data)
    }

    func urlSession(_ session: URLSession, didCompleteWithError error: Error?) {
        didCompleteWith(session: session, response: response, data: body, error: error, canRetry: true)
    }

    private func didCompleteWith(session: URLSession, response: URLResponse?, data: Data?, error: Error?, canRetry: Bool) {
        if let error = error {
            return finish(with: .failure(HTTPError(error: error)))
        }
        guard let response = response as? HTTPURLResponse else {
            return finish(with: .failure(HTTPError(kind: .malformedResponse)))
        }

        guard let body = data, response.statusCode < 400 else {
            if canRetry, var request = task.originalRequest, request.httpMethod?.uppercased() == "HEAD" {
                // It was a HEAD request, so we need to query the resource again to get the error body.
                request.httpMethod = "GET"
                session.dataTask(with: request) { data, response, error in
                    self.didCompleteWith(session: session, response: response, data: data, error: error, canRetry: false)
                }.resume()

            } else {
                finish(with: .failure(
                    HTTPError(statusCode: response.statusCode, mediaType: response.sniffMediaType { data ?? Data() }, body: data)
                        ?? HTTPError(kind: .malformedResponse)
                ))
            }
            return
        }

        return finish(with: .success((response: HTTPResponse(response: response, body: body), body: body)))
    }

    private var isFinished = false

    private func finish(with result: HTTPResult<HTTPFetchResponse>) {
        guard !isFinished else {
            return
        }
        isFinished = true

        switch result {
        case .success(let response):
            completion(.success(response))
        case .failure(let error):
            if error.kind != .cancelled {
                log(.error, "Fetch failed for: \(task.originalRequest?.url?.absoluteString ?? "N/A") with error: \(error.localizedDescription)")
            }
            completion(.failure(error))
        }
    }
}

/// Represents an on-going progressive download HTTP task.
private final class ProgressiveDownloadTask: Task, Loggable {

    enum ProgressiveDownloadError: LocalizedError {
        case byteRangesNotSupported(url: String)

        var errorDescription: String? {
            switch self {
            case .byteRangesNotSupported(let url):
                return R2SharedLocalizedString("ProgressiveDownloadError.byteRangesNotSupported", url)
            }
        }
    }

    let task: URLSessionTask
    private let receiveResponse: ((HTTPResponse) -> Void)?
    private let consumeData: (Data, Double?) -> Void
    private let completion: (HTTPResult<HTTPResponse>) -> Void

    private var response: HTTPURLResponse? = nil
    // FIXME: Use task.progress.fractionCompleted once we bump minimum iOS version to 11+
    private var readBytes: Int64 = 0
    private var expectedBytes: Int64? = nil

    init(task: URLSessionDataTask, receiveResponse: ((HTTPResponse) -> Void)?, consumeData: @escaping (Data, Double?) -> Void, completion: @escaping (HTTPResult<HTTPResponse>) -> Void) {
        self.task = task
        self.receiveResponse = receiveResponse
        self.consumeData = consumeData
        self.completion = completion
    }

    func urlSession(_ session: URLSession, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> ()) {
        guard !isFinished else {
            completionHandler(.cancel)
            return
        }

        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }

        self.response = response

        if response.statusCode < 400 {
            guard response.acceptsByteRanges else {
                let url = task.originalRequest?.url?.absoluteString ?? "N/A"
                log(.debug, url)
                for (k, v) in response.allHeaderFields {
                    log(.debug, "\(k) - \(v)")
                }
                log(.error, "Progressive download requires the remote HTTP server to support byte range requests: \(url)")
                finish(with: .failure(HTTPError(kind: .other, cause: ProgressiveDownloadError.byteRangesNotSupported(url: url))))

                completionHandler(.cancel)
                return
            }

            self.expectedBytes = (response.allHeaderFields["Content-Length"] as? String)
                .flatMap { Int64($0) }
                .takeIf { $0 > 0 }

            self.receiveResponse?(HTTPResponse(response: response))
        }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, didReceive data: Data) {
        guard !isFinished else {
            return
        }

        readBytes += Int64(data.count)
        var progress: Double? = nil
        if let expectedBytes = expectedBytes {
            progress = Double(min(readBytes, expectedBytes)) / Double(expectedBytes)
        }

        consumeData(data, progress)
    }

    func urlSession(_ session: URLSession, didCompleteWithError error: Error?) {
        if let error: HTTPError = {
            if let error = error {
                return HTTPError(error: error)
            } else if let response = response {
                return HTTPError(statusCode: response.statusCode)
            } else {
                return HTTPError(kind: .malformedResponse)
            }
        }() {
            finish(with: .failure(error))
        } else {
            finish(with: .success(()))
        }
    }

    private var isFinished = false

    private func finish(with result: HTTPResult<Void>) {
        guard !isFinished else {
            return
        }
        isFinished = true

        if case .failure(let error) = result, error.kind != .cancelled {
            log(.error, "Download (progressive) failed for: \(task.originalRequest?.url?.absoluteString ?? "N/A") with error: \(error.localizedDescription)")
        }

        guard let response = response else {
            completion(.failure(HTTPError(kind: .malformedResponse)))
            return
        }
        completion(result.map { HTTPResponse(response: response) })
    }

}

private extension URLRequest {

    mutating func setBytesRange(_ range: Range<UInt64>) {
        addValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
    }

}

private extension HTTPURLResponse {

    /// Indicates whether this server supports byte range requests.
    var acceptsByteRanges: Bool {
        return (allHeaderFields["Accept-Ranges"] as? String)?.lowercased() == "bytes"
            || (allHeaderFields["Content-Range"] as? String)?.lowercased().hasPrefix("bytes") == true
    }

}