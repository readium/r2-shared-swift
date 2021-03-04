//
//  Copyright 2021 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// Convenience protocol to pass an URL or similar request objects to an `HTTPClient`.
public protocol URLRequestConvertible {
    var urlRequest: URLRequest { get }
    var url: URL? { get }
}

extension URL: URLRequestConvertible {
    public var urlRequest: URLRequest { URLRequest(url: self) }
    public var url: URL? { self }
}

extension URLRequest: URLRequestConvertible {
    public var urlRequest: URLRequest { self }
}
