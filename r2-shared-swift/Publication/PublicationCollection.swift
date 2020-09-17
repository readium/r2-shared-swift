//
//  PublicationCollection.swift
//  r2-shared-swift
//
//  Created by Mickaël Menu on 11.03.19.
//
//  Copyright 2019 Readium Foundation. All rights reserved.
//  Use of this source code is governed by a BSD-style license which is detailed
//  in the LICENSE file present in the project repository where this source code is maintained.
//

import Foundation


/// Core Collection Model
/// https://readium.org/webpub-manifest/schema/subcollection.schema.json
/// Can be used as extension point in the Readium Web Publication Manifest.
public struct PublicationCollection: JSONEquatable {
    
    public let metadata: [String: Any]
    public let links: [Link]
    
    /// Subcollections indexed by their role in this collection.
    public let subcollections: [String: [PublicationCollection]]
    
    public init(metadata: [String: Any] = [:], links: [Link], subcollections: [String: [PublicationCollection]] = [:]) {
        self.metadata = metadata
        self.links = links
        self.subcollections = subcollections
    }
    
    public init(json: Any, normalizeHref: (String) -> String = { $0 }) throws {
        // Parses a list of links.
        if let json = json as? [[String: Any]] {
            self.init(links: .init(json: json, normalizeHref: normalizeHref))

        // Parses a Collection object.
        } else if var json = JSONDictionary(json) {
            self.init(
                metadata: json.pop("metadata") as? [String: Any] ?? [:],
                links: .init(json: json.pop("links"), normalizeHref: normalizeHref),
                subcollections: Self.makeCollections(json: json.json, normalizeHref: normalizeHref)
            )
            
        } else {
            self.init(links: [])
        }

        guard !links.isEmpty else {
            throw JSONError.parsing(PublicationCollection.self)
        }
    }
    
    public var json: [String: Any] {
        return makeJSON([
            "metadata": encodeIfNotEmpty(metadata),
            "links": links.json,
        ], additional: Self.serializeCollections(subcollections))
    }
    
    public static func == (lhs: PublicationCollection, rhs: PublicationCollection) -> Bool {
        guard #available(iOS 11.0, *) else {
            // The JSON comparison is not reliable before iOS 11, because the keys order is not deterministic. Since the equality is only tested during unit tests, it's not such a problem.
            return false
        }
        
        let lMetadata = try? JSONSerialization.data(withJSONObject: lhs.metadata, options: [.sortedKeys])
        let rMetadata = try? JSONSerialization.data(withJSONObject: rhs.metadata, options: [.sortedKeys])
        return lMetadata == rMetadata
            && lhs.links == rhs.links
            && lhs.subcollections == rhs.subcollections
    }
    
    static func makeCollections(json: Any?, normalizeHref: (String) -> String = { $0 }) -> [String: [PublicationCollection]] {
        guard let json = json as? [String: Any] else {
            return [:]
        }
        
        return json.compactMapValues { json in
            // Parses list of links or a single collection object.
            if let collection = try? PublicationCollection(json: json, normalizeHref: normalizeHref) {
                return [collection]

            // Parses list of collection objects.
            } else if let collections = json as? [[String: Any]] {
                return collections.compactMap {
                    try? PublicationCollection(json: $0, normalizeHref: normalizeHref)
                }

            } else {
                return nil
            }
        }
    }
    
    static func serializeCollections(_ collections: [String: [PublicationCollection]]) -> [String: Any] {
        return collections.compactMapValues { collections in
            if collections.isEmpty {
                return nil
            } else if collections.count == 1 {
                return collections[0].json
            } else {
                return collections.map { $0.json }
            }
        }
    }
    
}
