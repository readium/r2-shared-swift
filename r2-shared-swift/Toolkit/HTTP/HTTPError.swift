//
//  Copyright 2021 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

public typealias HTTPResult<Success> = Result<Success, HTTPError>
public typealias HTTPDeferred<Success> = Deferred<Success, HTTPError>

/// Represents an error occurring during an `HTTPClient` activity.
public struct HTTPError: LocalizedError, Equatable, Loggable {

    public enum Kind: Equatable {
        /// The provided request was not valid.
        case malformedRequest
        /// The received response couldn't be decoded.
        case malformedResponse
        /// The client, server or gateways timed out.
        case timeout
        /// (400) The server cannot or will not process the request due to an apparent client error.
        case badRequest
        /// (401) Authentication is required and has failed or has not yet been provided.
        case unauthorized
        /// (403) The server refuses the action, probably because we don't have the necessary
        /// permissions.
        case forbidden
        /// (404) The requested resource could not be found.
        case notFound
        /// (4xx) Other client errors
        case clientError
        /// (5xx) Server errors
        case serverError
        /// The device is offline.
        case offline
        /// The request was cancelled.
        case cancelled
        /// An error whose kind is not recognized.
        case other

        public init?(statusCode: Int) {
            switch statusCode {
            case 200..<400:
                return nil
            case 400:
                self = .badRequest
            case 401:
                self = .unauthorized
            case 403:
                self = .forbidden
            case 404:
                self = .notFound
            case 405...498:
                self = .clientError
            case 499:
                self = .cancelled
            case 500...599:
                self = .serverError
            default:
                self = .malformedResponse
            }
        }
    }

    /// Category of HTTP error.
    public let kind: Kind

    /// Underlying error, if any.
    public let cause: Error?

    /// Response media type.
    public let mediaType: MediaType?

    /// Response body.
    public let body: Data?

    /// Response body parsed as a JSON problem details.
    public let problemDetails: HTTPProblemDetails?

    public init(kind: Kind, cause: Error? = nil, mediaType: MediaType? = nil, body: Data? = nil) {
        self.kind = kind
        self.cause = cause
        self.mediaType = mediaType
        self.body = body

        self.problemDetails = {
            if let body = body, mediaType?.matches(.problemDetails) == true {
                do {
                    return try HTTPProblemDetails(data: body)
                } catch {
                    HTTPError.log(.error, "Failed to parse the JSON problem details: \(error)")
                }
            }
            return nil
        }()
    }

    public init?(statusCode: Int, mediaType: MediaType? = nil, body: Data? = nil) {
        guard let kind = Kind(statusCode: statusCode) else {
            return nil
        }
        self.init(kind: kind, mediaType: mediaType, body: body)
    }

    /// Creates an `HTTPError` from a native `URLError` or another error.
    public init(error: Error) {
        if let error = error as? HTTPError {
            self = error
            return
        }

        self.init(
            kind: {
                if let error = error as? URLError {
                    switch error.code {
                    case .badURL, .unsupportedURL:
                        return .badRequest
                    case .httpTooManyRedirects, .redirectToNonExistentLocation, .badServerResponse, .secureConnectionFailed:
                        return .serverError
                    case .zeroByteResource, .cannotDecodeContentData, .cannotDecodeRawData, .dataLengthExceedsMaximum:
                        return .malformedResponse
                    case .notConnectedToInternet, .networkConnectionLost:
                        return .offline
                    case .timedOut:
                        return .timeout
                    case .userAuthenticationRequired, .appTransportSecurityRequiresSecureConnection, .noPermissionsToReadFile:
                        return .forbidden
                    case .fileDoesNotExist:
                        return .notFound
                    case .cancelled, .userCancelledAuthentication:
                        return .cancelled
                    default:
                        break
                    }
                }
                return .other
            }(),
            cause: error
        )
    }

    public var errorDescription: String? {
        if let message = problemDetails?.title {
            return message
        }

        switch kind {
        case .malformedRequest:
            return R2SharedLocalizedString("HTTPError.malformedRequest")
        case .malformedResponse:
            return R2SharedLocalizedString("HTTPError.malformedResponse")
        case .timeout:
            return R2SharedLocalizedString("HTTPError.timeout")
        case .badRequest:
            return R2SharedLocalizedString("HTTPError.badRequest")
        case .unauthorized:
            return R2SharedLocalizedString("HTTPError.unauthorized")
        case .forbidden:
            return R2SharedLocalizedString("HTTPError.forbidden")
        case .notFound:
            return R2SharedLocalizedString("HTTPError.notFound")
        case .clientError:
            return R2SharedLocalizedString("HTTPError.clientError")
        case .serverError:
            return R2SharedLocalizedString("HTTPError.serverError")
        case .cancelled:
            return R2SharedLocalizedString("HTTPError.cancelled")
        case .offline:
            return R2SharedLocalizedString("HTTPError.offline")
        case .other:
            return (cause as? LocalizedError)?.errorDescription
        }
    }

    public static func ==(lhs: HTTPError, rhs: HTTPError) -> Bool {
        return lhs.kind == rhs.kind
            && lhs.mediaType == rhs.mediaType
            && lhs.body == rhs.body
            && lhs.problemDetails == rhs.problemDetails
    }

}
