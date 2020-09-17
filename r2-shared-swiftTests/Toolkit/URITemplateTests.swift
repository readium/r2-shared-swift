//
//  URITemplateTests.swift
//  r2-shared-swift
//
//  Created by Mickaël Menu on 05/06/2020.
//
//  Copyright 2020 Readium Foundation. All rights reserved.
//  Use of this source code is governed by a BSD-style license which is detailed
//  in the LICENSE file present in the project repository where this source code is maintained.
//

import XCTest
@testable import R2Shared

class URITemplateTests: XCTestCase {

    func testParameters() {
        XCTAssertEqual(
            URITemplate("/url{?x,hello,y}name{z,y,w}").parameters,
            ["x", "hello", "y", "z", "w"]
        )
    }
    
    func testParametersWithNoVariables() {
        XCTAssertEqual(URITemplate("/url").parameters, [])
    }
    
    func testExpandSimpleStringTemplates() {
        XCTAssertEqual(
            URITemplate("/url{x,hello,y}name{z,y,w}").expand(with: [
                "x": "aaa",
                "hello": "Hello, world",
                "y": "b",
                "z": "45",
                "w": "w"
            ]),
            "/urlaaa,Hello, world,bname45,b,w"
        )
    }
    
    func testExpandFormStyleAmpersandSeparatedTemplates() {
        XCTAssertEqual(
            URITemplate("/url{?x,hello,y}name").expand(with: [
                "x": "aaa",
                "hello": "Hello, world",
                "y": "b"
            ]),
            "/url?x=aaa&hello=Hello, world&y=bname"
        )
    }
    
    func testExpandIgnoresExtraParameters() {
        XCTAssertEqual(
            URITemplate("/path{?search}").expand(with: [
                "search": "banana",
                "code": "14"
            ]),
            "/path?search=banana"
        )
    }
    
    func testExpandWithNoVariables() {
        XCTAssertEqual(
            URITemplate("/path").expand(with: [
                "search": "banana",
            ]),
            "/path"
        )
    }

}
