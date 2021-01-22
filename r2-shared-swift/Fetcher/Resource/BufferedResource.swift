//
//  Copyright 2021 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// Wraps an existing `Resource` and buffers its content.
///
/// Expensive interaction with the underlying resource is minimized, since most (smaller) requests can be satisfied by
/// accessing the buffer alone. The drawback is that some extra space is required to hold the buffer and that copying
/// takes place when filling that buffer, but this is usually outweighed by the performance benefits.
///
/// Note that this implementation is pretty limited and the benefits are only apparent when reading forward and
/// consecutively – e.g. when downloading the resource by chunks. The buffer is ignored when reading backward or far
/// ahead.
public final class BufferedResource: ProxyResource {

    public init(resource: Resource, bufferSize: UInt64 = 8192) {
        assert(bufferSize > 0)
        self.bufferSize = bufferSize
        super.init(resource)
    }

    /// Size of the buffer chunks to read.
    let bufferSize: UInt64

    /// The buffer containing the current bytes read from the wrapped `Resource`, with the range it covers.
    private var buffer: (data: Data, range: Range<UInt64>)? = nil

    private lazy var cachedLength: ResourceResult<UInt64> = resource.length

    public override func read(range: Range<UInt64>?) -> ResourceResult<Data> {
        // Reading the whole resource bypasses buffering to keep things simple.
        guard
            var requestedRange = range,
            let length = cachedLength.getOrNil()
        else {
            return super.read(range: range)
        }

        requestedRange = requestedRange.clamped(to: 0..<length)
        guard !requestedRange.isEmpty else {
            return .success(Data())
        }

        let readUpperBound = min(requestedRange.upperBound.ceilMultiple(of: bufferSize), length)
        var readRange: Range<UInt64> = requestedRange.lowerBound..<readUpperBound

        if let buffer = buffer {
            // Everything already buffered?
            if buffer.range.contains(requestedRange) {
                let lower = (requestedRange.lowerBound - buffer.range.lowerBound)
                let upper = lower + (requestedRange.upperBound - requestedRange.lowerBound)
                assert(lower >= 0)
                assert(upper <= buffer.data.count)
                return .success(buffer.data[lower..<upper])

            // Beginning of requested data is buffered?
            } else if buffer.range.contains(requestedRange.lowerBound) {
                var data = buffer.data
                readRange = buffer.range.upperBound..<readRange.upperBound

                return super.read(range: readRange).map { readData in
                    data += readData

                    // Keep the last chunk of read data as the buffer for next reads.
                    let lastChunk = data.suffix(Int(bufferSize))
                    self.buffer = (
                        data: Data(lastChunk),
                        range: (readRange.upperBound - UInt64(lastChunk.count))..<readRange.upperBound
                    )

                    let lower = (requestedRange.lowerBound - buffer.range.lowerBound)
                    let upper = lower + (requestedRange.upperBound - requestedRange.lowerBound)
                    assert(lower >= 0)
                    assert(upper <= data.count)
                    return data[lower..<upper]
                }
            }
        }

        return super.read(range: readRange).map { data in
            // Keep the last chunk of read data as the buffer for next reads.
            let lastChunk = data.suffix(Int(bufferSize))
            buffer = (
                data: Data(lastChunk),
                range: (readRange.upperBound - UInt64(lastChunk.count))..<readRange.upperBound
            )

            return data[0..<requestedRange.count]
        }
    }

}

extension Resource {

    /// Wraps this resource in a `BufferedResource` to improve reading performances.
    public func buffered(size: UInt64 = 8192) -> BufferedResource {
        return BufferedResource(resource: self, bufferSize: size)
    }

}
