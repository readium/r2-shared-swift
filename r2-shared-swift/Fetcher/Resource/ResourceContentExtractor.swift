//
//  Copyright 2021 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import SwiftSoup

/// Extracts pure content from a marked-up (e.g. HTML) or binary (e.g. PDF) resource.
public protocol ResourceContentExtractor {

    /// Extracts the text content of the given `resource`.
    func extractText(of resource: Resource) -> ResourceResult<String>
}

public extension ResourceContentExtractor {
    func extractText(of resource: Resource) -> ResourceResult<String> {
        .success("")
    }
}

public protocol ResourceContentExtractorFactory {

    /// Creates a `ResourceContentExtractor` instance for the given `resource`.
    /// Returns null if the resource format is not supported.
    func makeExtractor(for resource: Resource) -> ResourceContentExtractor?
}

public class DefaultResourceContentExtractorFactory: ResourceContentExtractorFactory {

    public init() {}

    public func makeExtractor(for resource: Resource) -> ResourceContentExtractor? {
        switch resource.link.mediaType {
        case .html, .xhtml:
            return HTMLResourceContentExtractor()
        default:
            return nil
        }
    }
}

/// `ResourceContentExtractor` implementation for HTML resources.
class HTMLResourceContentExtractor: ResourceContentExtractor {

    func extractText(of resource: Resource) -> ResourceResult<String> {
        resource.readAsString()
            .flatMap { html in
                do {
                    var text = try SwiftSoup.parse(html).body()?.text() ?? ""
                    // Transform HTML entities into their actual characters.
                    text = try Entities.unescape(text)
                    return .success(text)

                } catch {
                    return .failure(.wrap(error))
                }
            }
    }

}