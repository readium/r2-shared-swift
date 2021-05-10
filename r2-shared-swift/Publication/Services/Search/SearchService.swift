//
//  Copyright 2021 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// Provides a way to search terms in a publication.
public protocol SearchService: PublicationService {

    /// All search options available for this service.
    ///
    /// Also holds the default value for these options, which can be useful to setup the views in the search interface.
    /// If an option is missing when calling search(), its value is assumed to be the default one.
    var options: Set<SearchOption> { get }

    /// Starts a new search through the publication content, with the given `query`.
    func search(query: String, options: Set<SearchOption>, completion: @escaping (SearchResult<SearchIterator>) -> Void) -> Cancellable
}

public extension SearchService {

    func search(query: String, completion: @escaping (SearchResult<SearchIterator>) -> Void) -> Cancellable {
        search(query: query, options: [], completion: completion)
    }

}

/// Iterates through search results.
public protocol SearchIterator {

    /// Number of matches for this search, if known.
    ///
    /// Depending on the search algorithm, it may not be possible to know the result count until reaching the end of the
    /// publication.
    var resultCount: Int? { get }

    /// Retrieves the next page of results.
    ///
    /// Returns nil when reaching the end of the publication, or an error in case of failure.
    func next(completion: @escaping (SearchResult<LocatorCollection?>) -> Void) -> Cancellable
}

/// Represents an option and its current value supported by a service.
public enum SearchOption: Hashable {
    /// Whether the search will differentiate between capital and lower-case letters.
    case caseSensitive(Bool)

    /// Whether the search will differentiate between letters with accents or not.
    case diacriticSensitive(Bool)

    /// Whether the query terms will match full words and not parts of a word.
    case wholeWord(Bool)

    /// Matches results exactly as stated in the query terms, taking into account stop words, order and spelling.
    case exact(Bool)

    /// BCP 47 language code overriding the publication's language.
    case language(String)

    /// A custom option implemented by a Search Service which is not officially recognized by Readium.
    case custom(key: String, value: String)
}

public typealias SearchResult<Success> = Result<Success, SearchError>

/// Represents an error which might occur during a search activity.
public enum SearchError: LocalizedError {

    /// The publication is not searchable.
    case publicationNotSearchable

    /// The provided search query cannot be handled by the service.
    case badQuery(LocalizedError)

    /// An error occurred while accessing one of the publication's resources.
    case resourceError(ResourceError)

    /// An error occurred while performing an HTTP request.
    case networkError(HTTPError)

    /// The search was cancelled by the caller.
    ///
    /// For example, when a network request is cancelled.
    case cancelled

    /// For any other custom service error.
    case other(Error)

    public static func wrap(_ error: Error) -> SearchError {
        switch error {
        case let error as SearchError:
            return error
        case let error as ResourceError:
            return .resourceError(error)
        case let error as HTTPError:
            return .networkError(error)
        default:
            return .other(error)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .publicationNotSearchable:
            return R2SharedLocalizedString("Publication.SearchError.publicationNotSearchable")
        case .badQuery(let error):
            return error.errorDescription
        case .resourceError(let error):
            return error.errorDescription
        case .networkError(let error):
            return error.errorDescription
        case .cancelled:
            return R2SharedLocalizedString("Publication.SearchError.cancelled")
        case .other:
            return R2SharedLocalizedString("Publication.SearchError.other")
        }
    }

}