//
//  Copyright 2021 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// Base implementation of `SearchService` iterating through the content of Publication's resources.
///
/// To stay media-type-agnostic, `StringSearchService` relies on `ResourceContentExtractor` implementations to retrieve
/// the pure text content from markups (e.g. HTML) or binary (e.g. PDF) resources.
public class StringSearchService: SearchService {

    public static func makeFactory(snippetLength: Int = 200, extractorFactory: ResourceContentExtractorFactory = DefaultResourceContentExtractorFactory()) -> (PublicationServiceContext) -> StringSearchService? {
        return { context in
            StringSearchService(
                publication: context.publication,
                language: context.manifest.metadata.languages.first,
                snippetLength: snippetLength,
                extractorFactory: extractorFactory
            )
        }
    }

    public let options: Set<SearchOption>

    private let publication: Weak<Publication>
    private let snippetLength: Int
    private let extractorFactory: ResourceContentExtractorFactory

    public init(publication: Weak<Publication>, language: String?, snippetLength: Int, extractorFactory: ResourceContentExtractorFactory) {
        self.publication = publication
        self.snippetLength = snippetLength
        self.extractorFactory = extractorFactory

        self.options = [
            .caseSensitive(false),
            .diacriticSensitive(false),
            .exact(false),
            .regularExpression(false),
            .language(language ?? Locale.current.languageCode ?? "en")
        ]
    }

    public func search(query: String, options: Set<SearchOption>, completion: @escaping (SearchResult<SearchIterator>) -> ()) -> Cancellable {
        let cancellable = CancellableObject()

        DispatchQueue.main.async(unlessCancelled: cancellable) {
            guard let publication = self.publication() else {
                completion(.failure(.cancelled))
                return
            }

            completion(.success(Iterator(
                publication: publication,
                snippetLength: self.snippetLength,
                extractorFactory: self.extractorFactory,
                query: query,
                options: options
            )))
        }

        return cancellable
    }

    private class Iterator: SearchIterator, Loggable {

        private(set) var resultCount: Int? = nil

        // Accumulates result count until we reach the end of the publication, to set `resultCount`.
        private var currentCount: Int = 0

        private let publication: Publication
        private let snippetLength: Int
        private let extractorFactory: ResourceContentExtractorFactory
        private let query: String
        private let options: Set<SearchOption>

        fileprivate init(
            publication: Publication,
            snippetLength: Int,
            extractorFactory: ResourceContentExtractorFactory,
            query: String,
            options: Set<SearchOption>
        ) {
            self.publication = publication
            self.snippetLength = snippetLength
            self.extractorFactory = extractorFactory
            self.query = query
            self.options = options
        }

        /// Index of the last reading order resource searched in.
        private var index = -1

        func next(completion: @escaping (SearchResult<LocatorCollection?>) -> ()) -> Cancellable {
            let cancellable = CancellableObject()
            DispatchQueue.global().async(unlessCancelled: cancellable) {
                self.findNext { result in
                    DispatchQueue.main.async(unlessCancelled: cancellable) {
                        completion(result)
                    }
                }
            }
            return cancellable
        }

        private func findNext(_ completion: @escaping (SearchResult<LocatorCollection?>) -> ()) {
            guard index < publication.readingOrder.count - 1 else {
                resultCount = currentCount
                completion(.success(nil))
                return
            }

            index += 1

            let link = publication.readingOrder[index]
            let resource = publication.get(link)

            do {
                guard let extractor = extractorFactory.makeExtractor(for: resource) else {
                    log(.warning, "Cannot extract text from resource: \(link.href)")
                    return findNext(completion)
                }
                let text = try extractor.extractText(of: resource).get()

                let locators = findLocators(in: link, resourceIndex: index, text: text)
                // If no occurrences were found in the current resource, skip to the next one automatically.
                guard !locators.isEmpty else {
                    return findNext(completion)
                }

                completion(.success(LocatorCollection(locators: locators)))

            } catch {
                completion(.failure(.wrap(error)))
            }
        }

        private func findLocators(in link: Link, resourceIndex: Int, text: String) -> [Locator] {
            guard !text.isEmpty else {
                return []
            }

            let title = publication.tableOfContents.titleMatchingHREF(link.href) ?? link.title
            let resourceLocator = Locator(link: link).copy(title: title)

            var locators: [Locator] = []

            for range in findRanges(text: text, query: query, options: options) {
                locators.append(makeLocator(resourceIndex: index, resourceLocator: resourceLocator, text: text, range: range))
            }

            return locators
        }

        private func findRanges(text: String, query: String, options: Set<SearchOption>) -> [Range<String.Index>] {
            var ranges: [Range<String.Index>] = []

            var compareOptions: NSString.CompareOptions = []
            let locale: Locale? = nil
            var index = text.startIndex
            while
                index < text.endIndex,
                let range = text.range(of: query, options: compareOptions, range: index..<text.endIndex, locale: locale),
                !range.isEmpty
            {
                ranges.append(range)
                index = text.index(range.lowerBound, offsetBy: 1)
            }

            return ranges
        }

        private func makeLocator(resourceIndex: Int, resourceLocator: Locator, text: String, range: Range<String.Index>) -> Locator {
            let progression = min(0.0, max(1.0, Double(range.lowerBound.utf16Offset(in: text)) / Double(text.endIndex.utf16Offset(in: text))))

            var totalProgression: Double? = nil
            let positions = publication.positionsByReadingOrder
            if let resourceStartTotalProg = positions.getOrNil(resourceIndex)?.first?.locations.totalProgression {
                let resourceEndTotalProg = positions.getOrNil(resourceIndex + 1)?.first?.locations.totalProgression ?? 1.0
                totalProgression = resourceStartTotalProg + progression * (resourceEndTotalProg - resourceStartTotalProg)
            }

            return resourceLocator.copy(
                locations: {
                    $0.progression = progression
                    $0.totalProgression = totalProgression
                },
                text: {
                    $0 = self.makeSnippet(text: text, range: range)
                }
            )
        }

        /// Extracts a snippet from the given `text` at the provided highlight `range`.
        /// Makes sure that words are not cut off at the boundaries.
        private func makeSnippet(text: String, range: Range<String.Index>) -> Locator.Text {
            var before = ""
            var count = snippetLength
            for char in text[...range.lowerBound].reversed() {
                guard count >= 0 || !char.isWhitespace else {
                    break
                }
                count -= 1
                before.insert(char, at: before.startIndex)
            }

            var after = ""
            count = snippetLength
            for char in text[range.upperBound...] {
                guard count >= 0 || !char.isWhitespace else {
                    break
                }
                count -= 1
                after.append(char)
            }

            return Locator.Text(
                after: after,
                before: before,
                highlight: String(text[range])
            )
        }
    }
}

fileprivate extension Array where Element == Link {
    func titleMatchingHREF(_ href: String) -> String? {
        for link in self {
            if let title = link.titleMatchingHREF(href) {
                return title
            }
        }
        return nil
    }
}

fileprivate extension Link {
    func titleMatchingHREF(_ targetHREF: String) -> String? {
        if (href.substringBeforeLast("#") == targetHREF) {
            return title
        }
        return children.titleMatchingHREF(targetHREF)
    }
}

fileprivate extension DispatchQueue {
    func async(unlessCancelled cancellable: Cancellable, execute work: @escaping () -> Void) {
        async {
            guard !cancellable.isCancelled else {
                return
            }
            work()
        }
    }
}