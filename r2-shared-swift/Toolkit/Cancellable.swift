//
//  Copyright 2021 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// A protocol indicating that an activity or action supports cancellation.
public protocol Cancellable {

    /// Cancel the on-going activity.
    func cancel()

}

/// A `Cancellable` object saving its cancelled state.
public final class CancellableObject: Cancellable {
    public private(set) var isCancelled = false

    public func cancel() {
        isCancelled = true
    }
}
