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

    public init(baseURL: URL? = nil) {
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
        return HTTPResource(link: link, url: url)
    }
    
    public func close() { }

    /// Base URL from which relative HREF are served.
    private let baseURL: URL?

    /// HTTPResource provides access to an external URL.
    final class HTTPResource: NSObject, Resource, Loggable, URLSessionDataDelegate {

        let link: Link
        let url: URL

        init(link: Link, url: URL) {
            self.link = link
            self.url = url
        }

        var length: ResourceResult<UInt64> {
            headResponse.flatMap {
                let length = $0.expectedContentLength
                if length < 0 {
                    return .failure(.unavailable)
                } else {
                    return .success(UInt64(length))
                }
            }
        }

        /// Cached HEAD response to get the expected content length and other metadata.
        private lazy var headResponse: ResourceResult<HTTPURLResponse> = {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            return URLSession.shared.synchronousDataTask(with: request)
                .map { data, response in response }
        }()

        /// An HTTP resource is always remote.
        var file: URL? { nil }

        func read(range: Range<UInt64>?, consume: @escaping (Data) -> (), completion: @escaping (ResourceResult<()>) -> ()) -> Cancellable {
            var request = URLRequest(url: url)
            if let range = range {
                request.setBytesRange(range)
            }

            let task = Task(
                task: urlSession.dataTask(with: request),
                consume: consume,
                completion: completion
            )
            tasks.append(task)
            task.start()

            return task
        }

        func close() {
            tasks.forEach { $0.cancel() }
            tasks.removeAll()
        }

        // MARK: – Task Management

        private lazy var urlSession =
            URLSession(configuration: .default, delegate: self, delegateQueue: nil)

        /// Represents an on-going HTTP fetch task.
        private final class Task: Cancellable {
            let task: URLSessionDataTask
            /// Will be called with every chunk of data received.
            let consume: (Data) -> Void
            private var isFinished = false
            private let completion: (ResourceResult<Void>) -> Void

            init(task: URLSessionDataTask, consume: @escaping (Data) -> Void, completion: @escaping (ResourceResult<Void>) -> Void) {
                self.task = task
                self.consume = consume
                self.completion = completion
            }

            func start() {
                task.resume()
            }

            func cancel() {
                task.cancel()
                finish(with: .failure(.cancelled))
            }

            func finish(with result: ResourceResult<Void>) {
                guard !isFinished else {
                    return
                }
                isFinished = true
                completion(result)
            }
        }

        // On-going tasks.
        private var tasks: [Task] = []

        private func finishTask(_ task: URLSessionTask, withError error: ResourceError?) {
            guard let index = tasks.firstIndex(where: { $0.task == task}) else {
                return
            }

            let task = tasks.remove(at: index)
            if let error = error {
                task.finish(with: .failure(error))
            } else {
                task.finish(with: .success(()))
            }
        }

        // MARK: - URLSessionDataDelegate

        // FIXME: Disable caching?
//        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse, completionHandler: @escaping (CachedURLResponse?) -> ()) {
//        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> ()) {
            if let error = response.resourceError {
                finishTask(dataTask, withError: error)
                completionHandler(.cancel)
            } else {
                completionHandler(.allow)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let task = tasks.first(where: { $0.task == dataTask }) else {
                return
            }

            task.consume(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            finishTask(task, withError: error.map { .other($0) })
        }
    }

}

private extension URLResponse {

    var resourceError: ResourceError? {
        guard let response = self as? HTTPURLResponse else {
            return .other(HTTPFetcher.HTTPError.serverFailure)
        }

        // FIXME: 3xx
        switch response.statusCode {
        case 200..<300:
            return nil
        case 401, 403:
            return .forbidden
        case 404:
            return .notFound
        case 503:
            return .unavailable
        default:
            return .other(HTTPFetcher.HTTPError.serverFailure)
        }
    }

}

private extension URLSession {

    func synchronousDataTask(with request: URLRequest) -> ResourceResult<(Data, HTTPURLResponse)> {
        var data: Data?
        var response: URLResponse?
        var error: Error?

        let semaphore = DispatchSemaphore(value: 0)
        let dataTask = self.dataTask(with: request) {
            data = $0
            response = $1
            error = $2
            semaphore.signal()
        }
        dataTask.resume()

        _ = semaphore.wait(timeout: .distantFuture)

        guard error == nil, let httpResponse = response as? HTTPURLResponse else {
            return .failure(.other(error ?? HTTPFetcher.HTTPError.serverFailure))
        }

        if let error = httpResponse.resourceError {
            return .failure(error)
        } else {
            return .success((data ?? Data(), httpResponse))
        }
    }
    
}

private extension HTTPURLResponse {
    
    func value(forHTTPHeaderField field: String) -> String? {
        return allHeaderFields[field] as? String
    }
    
    var acceptsRanges: Bool {
        let header = value(forHTTPHeaderField: "Accept-Ranges")
        return header != nil && header != "none"
    }
    
}

private extension URLRequest {
    
    mutating func setBytesRange(_ range: Range<UInt64>) {
        addValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
    }
    
}
