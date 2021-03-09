//
//  Copyright 2021 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// Delegate protocol for `DefaultHTTPClient`.
public protocol DefaultHTTPClientDelegate: class {

    /// Tells the delegate that the HTTP client will start a new `request`.
    ///
    /// Warning: You MUST call the `completion` handler with the request to start, otherwise the client will hang.
    ///
    /// You can modify the `request`, for example by adding additional HTTP headers or redirecting to a different URL,
    /// before calling the `completion` handler with the new request.
    func httpClient(_ httpClient: DefaultHTTPClient, willStartRequest request: URLRequest, completion: @escaping (HTTPResult<URLRequestConvertible>) -> Void)

    /// Asks the delegate to recover from an `error` received for the given `request`.
    ///
    /// This can be used to implement custom authentication flows, for example.
    ///
    /// You can call the `completion` handler with either:
    ///   * a new request to start
    ///   * the `error` argument, if you cannot recover from it
    ///   * a new `HTTPError` to provide additional information
    func httpClient(_ httpClient: DefaultHTTPClient, recoverRequest request: URLRequest, fromError error: HTTPError, completion: @escaping (HTTPResult<URLRequestConvertible>) -> Void)

    /// Tells the delegate that we received an HTTP response for the given `request`.
    ///
    /// You do not need to do anything with this `response`, which the HTTP client will handle. This is merely for
    /// informational purposes. For example, you could implement this to confirm that request credentials were
    /// successful.
    func httpClient(_ httpClient: DefaultHTTPClient, request: URLRequest, didReceiveResponse response: HTTPResponse)

    /// Tells the delegate that a `request` failed with the given `error`.
    ///
    /// You do not need to do anything with this `response`, which the HTTP client will handle. This is merely for
    /// informational purposes.
    ///
    /// This will be called only if `httpClient(_:recoverRequest:fromError:completion:)` is not implemented, or returns
    /// an error.
    func httpClient(_ httpClient: DefaultHTTPClient, request: URLRequest, didFailWithError error: HTTPError)

}

public extension DefaultHTTPClientDelegate {

    func httpClient(_ httpClient: DefaultHTTPClient, willStartRequest request: URLRequest, completion: @escaping (HTTPResult<URLRequestConvertible>) -> ()) {
        completion(.success(request))
    }

    func httpClient(_ httpClient: DefaultHTTPClient, recoverRequest request: URLRequest, fromError error: HTTPError, completion: @escaping (HTTPResult<URLRequestConvertible>) -> ()) {
        completion(.failure(error))
    }

    func httpClient(_ httpClient: DefaultHTTPClient, request: URLRequest, didReceiveResponse response: HTTPResponse) {}
    func httpClient(_ httpClient: DefaultHTTPClient, request: URLRequest, didFailWithError error: HTTPError) {}

}

/// An implementation of `HTTPClient` using native APIs.
public final class DefaultHTTPClient: NSObject, HTTPClient, Loggable, URLSessionDataDelegate {

    /// Creates a `DefaultHTTPClient` with common configuration settings.
    ///
    /// - Parameters:
    ///   - ephemeral: When true, uses no persistent storage for caches, cookies, or credentials.
    ///   - cachePolicy: Determines the request caching policy used by HTTP tasks.
    ///   - additionalHeaders: A dictionary of additional headers to send with requests. For example, `User-Agent`.
    ///   - requestTimeout: The timeout interval to use when waiting for additional data.
    ///   - resourceTimeout: The maximum amount of time that a resource request should be allowed to take.
    ///   - configure: Callback used to configure further the `URLSessionConfiguration` object.
    public convenience init(
        cachePolicy: URLRequest.CachePolicy? = nil,
        ephemeral: Bool = false,
        additionalHeaders: [AnyHashable: Any]? = nil,
        requestTimeout: TimeInterval? = nil,
        resourceTimeout: TimeInterval? = nil,
        delegate: DefaultHTTPClientDelegate? = nil,
        configure: ((URLSessionConfiguration) -> Void)? = nil
    ) {
        let config: URLSessionConfiguration = ephemeral ? .ephemeral : .default
        config.httpAdditionalHeaders = additionalHeaders
        if let cachePolicy = cachePolicy {
            config.requestCachePolicy = cachePolicy
        }
        if let requestTimeout = requestTimeout {
            config.timeoutIntervalForRequest = requestTimeout
        }
        if let resourceTimeout = resourceTimeout {
            config.timeoutIntervalForResource = resourceTimeout
        }
        if let configure = configure {
            configure(config)
        }

        self.init(configuration: config, delegate: delegate)
    }

    /// Creates a `DefaultHTTPClient` with a custom configuration.
    public init(configuration: URLSessionConfiguration, delegate: DefaultHTTPClientDelegate? = nil) {
        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.delegate = delegate
    }

    public weak var delegate: DefaultHTTPClientDelegate? = nil

    private var session: URLSession!

    deinit {
        session.invalidateAndCancel()
    }

    public func fetch(_ request: URLRequestConvertible, completion: @escaping (HTTPResult<HTTPFetchResponse>) -> ()) -> Cancellable {
        return startRequest(request,
            makeTask: { request, completion in
                FetchTask(
                    client: self,
                    task: self.session.dataTask(with: request),
                    completion: completion
                )
            },
            completion: completion
        )
    }

    public func progressiveDownload(_ request: URLRequestConvertible, range: Range<UInt64>?, receiveResponse: ((HTTPResponse) -> Void)?, consumeData: @escaping (Data, Double?) -> Void, completion: @escaping (HTTPResult<HTTPResponse>) -> Void) -> Cancellable {
        var request = request.urlRequest
        if let range = range {
            request.setBytesRange(range)
        }

        return startRequest(request,
            makeTask: { request, completion in
                ProgressiveDownloadTask(
                    client: self,
                    task: self.session.dataTask(with: request),
                    isByteRangeRequest: range != nil,
                    receiveResponse: receiveResponse,
                    consumeData: consumeData,
                    completion: completion
                )
            },
            completion: completion
        )
    }

    /// Prepares and start a new HTTP request, using the given `Task` factory.
    private func startRequest<T>(
        _ request: URLRequestConvertible,
        makeTask: @escaping (_ request: URLRequest, _ completion: @escaping (HTTPResult<T>) -> Void) -> Task,
        completion: @escaping (HTTPResult<T>) -> Void
    ) -> Cancellable {

        let mediator = MediatorCancellable()

        /// Attempts to start a `request`.
        /// Will try to recover from errors using the `delegate` and calling itself again.
        func tryStart(_ request: URLRequestConvertible) -> HTTPDeferred<T> {
            let request = request.urlRequest

            return willStartRequest(request)
                .flatMap(requireNotCancelled)
                .flatMap { request in
                    let request = request.urlRequest

                    return startTask(for: request)
                        .flatCatch { error in
                            recoverRequest(request, fromError: error)
                                .flatMap(requireNotCancelled)
                                .flatMap { newRequest in
                                    tryStart(newRequest)
                                }
                        }
                }
        }

        /// Will interrupt the flow if the `mediator` received a cancel request.
        func requireNotCancelled<T>(_ value: T) -> HTTPDeferred<T> {
            if mediator.isCancelled {
                return .failure(HTTPError(kind: .cancelled))
            } else {
                return .success(value)
            }
        }

        /// Creates and starts a new task for the `request`, whose cancellable will be exposed through `mediator`.
        func startTask(for request: URLRequest) -> HTTPDeferred<T> {
            deferred { completion in
                let task = makeTask(request) { result in
                    completion(CancellableResult(result))
                }

                let cancellable = self.start(task)
                mediator.mediate(cancellable)
            }
        }

        /// Lets the `delegate` customize the `request` if needed, before actually starting it.
        func willStartRequest(_ request: URLRequest) -> HTTPDeferred<URLRequestConvertible> {
            deferred { completion in
                if let delegate = self.delegate {
                    delegate.httpClient(self, willStartRequest: request) { completion(CancellableResult($0)) }
                } else {
                    completion(.success(request))
                }
            }
        }

        /// Attempts to recover from a `error` by asking the `delegate` for a new request.
        func recoverRequest(_ request: URLRequest, fromError error: HTTPError) -> HTTPDeferred<URLRequestConvertible> {
            deferred { completion in
                if let delegate = self.delegate {
                    delegate.httpClient(self, recoverRequest: request, fromError: error) { completion(CancellableResult($0)) }
                } else {
                    completion(.failure(error))
                }
            }
        }

        tryStart(request)
            .resolve(on: .main) { result in
                // Convert a `CancellableResult` to an `HTTPResult`, as expected by the `completion` handler.
                let result = result.result(withCancelledError: HTTPError(kind: .cancelled))
                completion(result)
            }

        return mediator
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
        tasks[i].urlSession(session, didCompleteWithError: error)
    }

}

/// Represents an on-going HTTP task.
private protocol Task: Cancellable {
    var task: URLSessionTask { get }

    func start()
    func urlSession(_ session: URLSession, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> ())
    func urlSession(_ session: URLSession, didReceive data: Data)
    func urlSession(_ session: URLSession, didCompleteWithError error: Error?)
}

private class BaseTask<T>: Task, Loggable {

    class var title: String {
        fatalError("To override in subclasses")
    }

    weak var client: DefaultHTTPClient?
    let task: URLSessionTask
    private(set) var isFinished = false
    private let completion: (HTTPResult<T>) -> Void

    init(client: DefaultHTTPClient?, task: URLSessionTask, completion: @escaping (HTTPResult<T>) -> Void) {
        self.client = client
        self.task = task
        self.completion = completion
    }

    func start() {
        if let request = task.originalRequest {
            self.log(.info, "\(Self.title) (\(request.httpMethod ?? "GET")) \(request.url?.absoluteString ?? "nil"), headers: \(request.allHTTPHeaderFields ?? [:])")
        }

        task.resume()
    }

    func cancel() {
        task.cancel()
    }

    func finish(with result: HTTPResult<T>) {
        guard !isFinished else {
            return
        }
        isFinished = true

        if case .failure(let error) = result, error.kind != .cancelled {
            log(.error, "\(Self.title) failed for: \(task.originalRequest?.url?.absoluteString ?? "N/A") with error: \(error.localizedDescription)")

            if let client = client, let request = task.originalRequest {
                client.delegate?.httpClient(client, request: request, didFailWithError: error)
            }
        }

        completion(result)
    }

    func didReceiveResponse(_ response: HTTPResponse) {
        if let client = client, let request = task.originalRequest {
            client.delegate?.httpClient(client, request: request, didReceiveResponse: response)
        }
    }

    func urlSession(_ session: URLSession, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> ()) {
        fatalError("To implement in subclasses")
    }

    func urlSession(_ session: URLSession, didReceive data: Data) {
        fatalError("To implement in subclasses")
    }

    func urlSession(_ session: URLSession, didCompleteWithError error: Error?) {
        fatalError("To implement in subclasses")
    }

}

/// Represents an on-going fetch HTTP task.
private final class FetchTask: BaseTask<HTTPFetchResponse> {
    override class var title: String { "Fetch" }

    private var response: HTTPURLResponse? = nil
    /// Body data accumulator.
    private var body = Data()

    override func urlSession(_ session: URLSession, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> ()) {
        guard !isFinished else {
            completionHandler(.cancel)
            return
        }

        self.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    override func urlSession(_ session: URLSession, didReceive data: Data) {
        guard !isFinished else {
            return
        }

        body.append(data)
    }

    override func urlSession(_ session: URLSession, didCompleteWithError error: Error?) {
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
                // It was a HEAD request, we need to query the resource again to get the error body.
                /// The body is needed for example when the response is an OPDS Authentication Document.
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

        let httpResponse = HTTPResponse(response: response, body: body)
        didReceiveResponse(httpResponse)
        finish(with: .success((response: httpResponse, body: body)))
    }
}

/// Represents an on-going progressive download HTTP task.
private final class ProgressiveDownloadTask: BaseTask<HTTPResponse> {
    override class var title: String { "Download (progressive)" }

    enum ProgressiveDownloadError: LocalizedError {
        case byteRangesNotSupported(url: String)

        var errorDescription: String? {
            switch self {
            case .byteRangesNotSupported(let url):
                return R2SharedLocalizedString("ProgressiveDownloadError.byteRangesNotSupported", url)
            }
        }
    }

    /// States the progressive download task can be in.
    private enum State {
        /// Waiting for the HTTP response.
        case loading
        /// We received a success response, the data will be sent to `consumeData` progressively.
        case download(HTTPResponse, readBytes: Int64)
        /// We received an error response, the data will be accumulated in `body` to make the final `HTTPError`.
        /// The body is needed for example when the response is an OPDS Authentication Document.
        case error(HTTPError, body: Data)
    }

    private var state: State = .loading

    private let isByteRangeRequest: Bool
    private let receiveResponse: ((HTTPResponse) -> Void)?
    private let consumeData: (Data, Double?) -> Void

    init(client: DefaultHTTPClient?, task: URLSessionDataTask, isByteRangeRequest: Bool, receiveResponse: ((HTTPResponse) -> Void)?, consumeData: @escaping (Data, Double?) -> Void, completion: @escaping (HTTPResult<HTTPResponse>) -> Void) {
        self.isByteRangeRequest = isByteRangeRequest
        self.receiveResponse = receiveResponse
        self.consumeData = consumeData

        super.init(client: client, task: task, completion: completion)
    }

    override func urlSession(_ session: URLSession, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> ()) {
        guard !isFinished else {
            completionHandler(.cancel)
            return
        }

        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }

        if let error = HTTPError(statusCode: response.statusCode, mediaType: response.sniffMediaType()) {
            state = .error(error, body: Data())

        } else {
            guard !isByteRangeRequest || response.acceptsByteRanges else {
                let url = task.originalRequest?.url?.absoluteString ?? "N/A"
                log(.debug, url)
                for (k, v) in response.allHeaderFields {
                    log(.debug, "\(k) - \(v)")
                }
                log(.error, "Progressive download using ranges requires the remote HTTP server to support byte range requests: \(url)")
                finish(with: .failure(HTTPError(kind: .other, cause: ProgressiveDownloadError.byteRangesNotSupported(url: url))))

                completionHandler(.cancel)
                return
            }

            let clientResponse = HTTPResponse(response: response)
            state = .download(clientResponse, readBytes: 0)
            self.receiveResponse?(clientResponse)

        }

        completionHandler(.allow)
    }

    override func urlSession(_ session: URLSession, didReceive data: Data) {
        guard !isFinished else {
            return
        }

        switch state {
        case .loading:
            break

        case .download(let response, var readBytes):
            readBytes += Int64(data.count)
            // FIXME: Use task.progress.fractionCompleted once we bump minimum iOS version to 11+
            var progress: Double? = nil
            if let expectedBytes = response.contentLength {
                progress = Double(min(readBytes, expectedBytes)) / Double(expectedBytes)
            }
            consumeData(data, progress)
            state = .download(response, readBytes: readBytes)

        case .error(let error, var body):
            body.append(data)
            state = .error(error, body: body)
        }
    }

    override func urlSession(_ session: URLSession, didCompleteWithError error: Error?) {
        guard !isFinished else {
            return
        }

        if let error = error {
            finish(with: .failure(HTTPError(error: error)))
            return
        }

        switch state {
        case .loading:
            preconditionFailure("ProgressiveDownloadTask.didCompleteWithError called in loading state")

        case let .download(response, _):
            finish(with: .success(response))

        case let .error(error, body):
            finish(with: .failure(HTTPError(kind: error.kind, mediaType: error.mediaType, body: body)))
        }
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