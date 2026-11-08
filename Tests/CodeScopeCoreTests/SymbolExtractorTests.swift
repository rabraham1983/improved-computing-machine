import XCTest
@testable import CodeScopeCore

final class SymbolExtractorTests: XCTestCase {

    func testSwiftSymbolsAndImports() {
        let source = """
        import Foundation
        @testable import CodeScopeCore

        public final class Parser {
            public init(input: String) {}
            func parse() -> Int { 0 }
            class func make() -> Parser { Parser(input: "") }
        }

        struct Token {}
        enum Kind { case a }
        protocol Visitor {}
        extension Parser: Visitor {}
        let topLevel = 42
        """
        let result = SymbolExtractor.extract(content: source, language: .swift)
        XCTAssertEqual(result.imports, ["Foundation", "CodeScopeCore"])

        let names = result.symbols.map { "\($0.kind.rawValue):\($0.name)" }
        XCTAssertTrue(names.contains("class:Parser"))
        XCTAssertTrue(names.contains("initializer:init"))
        XCTAssertTrue(names.contains("method:parse"))
        XCTAssertTrue(names.contains("method:make"))
        XCTAssertTrue(names.contains("struct:Token"))
        XCTAssertTrue(names.contains("enum:Kind"))
        XCTAssertTrue(names.contains("protocol:Visitor"))
        XCTAssertTrue(names.contains("extension:Parser"))
        XCTAssertTrue(names.contains("variable:topLevel"))
        XCTAssertEqual(result.symbols.first { $0.name == "Parser" && $0.kind == .class }?.line, 4)
    }

    func testPythonSymbols() {
        let source = """
        import os
        from collections import defaultdict
        from .local import helper

        MAX_SIZE = 10

        class Repo:
            def __init__(self):
                pass

            async def fetch(self):
                pass

        def main():
            if __name__ == "__main__":
                main()
        """
        let result = SymbolExtractor.extract(content: source, language: .python)
        XCTAssertEqual(result.imports, ["os", "collections", ".local"])
        let names = result.symbols.map { "\($0.kind.rawValue):\($0.name)" }
        XCTAssertTrue(names.contains("constant:MAX_SIZE"))
        XCTAssertTrue(names.contains("class:Repo"))
        XCTAssertTrue(names.contains("method:__init__"))
        XCTAssertTrue(names.contains("method:fetch"))
        XCTAssertTrue(names.contains("function:main"))
    }

    func testJavaScriptSymbols() {
        let source = """
        import React from 'react';
        import { helper } from './utils/helper';
        const fs = require('fs');

        export default function App() {}
        export const load = async (id) => { return id; };
        class Store {
          constructor() {}
          get(key) {
            return this.map[key];
          }
        }
        interface Props { id: string }
        type ID = string;
        """
        let result = SymbolExtractor.extract(content: source, language: .typescript)
        XCTAssertEqual(result.imports, ["react", "./utils/helper", "fs"])
        let names = result.symbols.map { "\($0.kind.rawValue):\($0.name)" }
        XCTAssertTrue(names.contains("function:App"))
        XCTAssertTrue(names.contains("function:load"))
        XCTAssertTrue(names.contains("class:Store"))
        XCTAssertTrue(names.contains("method:constructor"))
        XCTAssertTrue(names.contains("method:get"))
        XCTAssertTrue(names.contains("interface:Props"))
        XCTAssertTrue(names.contains("type:ID"))
        XCTAssertFalse(names.contains { $0.hasSuffix(":if") || $0.hasSuffix(":return") })
    }

    func testGoSymbolsAndImportBlock() {
        let source = """
        package main

        import (
            "fmt"
            log "github.com/sirupsen/logrus"
        )

        type Server struct {}

        func (s *Server) Start() error { return nil }

        func main() {
            fmt.Println("hi")
        }
        """
        let result = SymbolExtractor.extract(content: source, language: .go)
        XCTAssertEqual(result.imports, ["fmt", "github.com/sirupsen/logrus"])
        let names = result.symbols.map { "\($0.kind.rawValue):\($0.name)" }
        XCTAssertTrue(names.contains("struct:Server"))
        XCTAssertTrue(names.contains("method:Start"))
        XCTAssertTrue(names.contains("function:main"))
    }

    func testCFamilyFunctions() {
        let source = """
        #include <stdio.h>
        #include "util.h"
        #define LIMIT 10

        static int helper(int a, int b) {
            if (a > b) {
                return a;
            }
            return b;
        }

        int main(int argc, char **argv)
        {
            return helper(1, 2);
        }
        """
        let result = SymbolExtractor.extract(content: source, language: .c)
        XCTAssertEqual(result.imports, ["stdio.h", "util.h"])
        let names = result.symbols.map { "\($0.kind.rawValue):\($0.name)" }
        XCTAssertTrue(names.contains("macro:LIMIT"))
        XCTAssertTrue(names.contains("function:helper"))
        XCTAssertTrue(names.contains("function:main"))
        XCTAssertFalse(names.contains { $0.hasSuffix(":if") })
    }

    func testMetrics() {
        let source = """
        // comment
        func a() {
            if x && y { }

        }
        """
        let metrics = MetricsCalculator.compute(content: source, language: .swift)
        XCTAssertEqual(metrics.totalLines, 5)
        XCTAssertEqual(metrics.commentLines, 1)
        XCTAssertEqual(metrics.blankLines, 1)
        XCTAssertEqual(metrics.codeLines, 3)
        XCTAssertEqual(metrics.complexity, 3) // if + &&
    }

    func testLanguageDetection() {
        XCTAssertEqual(Language.detect(fileName: "Main.swift"), .swift)
        XCTAssertEqual(Language.detect(fileName: "index.tsx"), .typescript)
        XCTAssertEqual(Language.detect(fileName: "Makefile"), .makefile)
        XCTAssertEqual(Language.detect(fileName: "Dockerfile.prod"), .dockerfile)
        XCTAssertEqual(Language.detect(fileName: "weird.unknownext"), .other)
    }
}
