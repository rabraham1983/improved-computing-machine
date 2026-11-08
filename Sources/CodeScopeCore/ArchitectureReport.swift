import Foundation

/// Structured understanding of a codebase produced by Claude via structured outputs.
public struct ArchitectureReport: Codable, Sendable, Equatable {
    public struct LanguageRole: Codable, Sendable, Equatable, Hashable {
        public var name: String
        public var role: String
    }

    public struct EntryPointDescription: Codable, Sendable, Equatable, Hashable {
        public var path: String
        public var description: String
    }

    public struct Component: Codable, Sendable, Equatable, Hashable {
        public var name: String
        public var responsibility: String
        public var files: [String]
        public var keyTypes: [String]
        public var interactsWith: [String]
    }

    public struct FlowStep: Codable, Sendable, Equatable, Hashable {
        public var step: String
        public var description: String
        public var files: [String]
    }

    public struct Dependency: Codable, Sendable, Equatable, Hashable {
        public var name: String
        public var purpose: String
    }

    public struct Concern: Codable, Sendable, Equatable, Hashable {
        public var title: String
        public var severity: String
        public var detail: String
        public var files: [String]
    }

    public struct Opportunity: Codable, Sendable, Equatable, Hashable {
        public var title: String
        public var category: String
        public var impact: String
        public var effort: String
        public var detail: String
        public var files: [String]
        public var suggestedPrompt: String
    }

    public struct GlossaryEntry: Codable, Sendable, Equatable, Hashable {
        public var term: String
        public var meaning: String
    }

    public var title: String
    public var oneLiner: String
    public var purpose: String
    public var architectureStyle: String
    public var languages: [LanguageRole]
    public var entryPoints: [EntryPointDescription]
    public var components: [Component]
    public var executionFlow: [FlowStep]
    public var dataFlow: String
    public var externalDependencies: [Dependency]
    public var buildAndRun: String
    public var concerns: [Concern]
    public var optimizationOpportunities: [Opportunity]
    public var glossary: [GlossaryEntry]

    public static func decode(from text: String) throws -> ArchitectureReport {
        let trimmed = ArchitectureReport.stripFences(text)
        return try JSONDecoder().decode(ArchitectureReport.self, from: Data(trimmed.utf8))
    }

    static func stripFences(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            if let newline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: newline)...])
            }
            if trimmed.hasSuffix("```") {
                trimmed = String(trimmed.dropLast(3))
            }
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// JSON schema for `output_config.format`. Every object lists all properties as required and
    /// forbids additional properties, as structured outputs demand.
    public static let schema: JSONValue = {
        func object(_ properties: [String: JSONValue]) -> JSONValue {
            [
                "type": "object",
                "properties": .object(properties),
                "required": .strings(properties.keys.sorted()),
                "additionalProperties": false
            ]
        }
        func array(_ items: JSONValue) -> JSONValue {
            ["type": "array", "items": items]
        }
        let string: JSONValue = ["type": "string"]
        let strings = array(string)

        return object([
            "title": ["type": "string", "description": "Short name for the application"],
            "oneLiner": ["type": "string", "description": "One sentence: what the application is and does"],
            "purpose": ["type": "string", "description": "Two or three paragraphs on what problem it solves and for whom"],
            "architectureStyle": ["type": "string", "description": "e.g. layered MVC web service, SwiftUI MVVM app, CLI pipeline — with a sentence of justification"],
            "languages": array(object(["name": string, "role": string])),
            "entryPoints": array(object(["path": string, "description": string])),
            "components": array(object([
                "name": string,
                "responsibility": string,
                "files": strings,
                "keyTypes": strings,
                "interactsWith": ["type": "array", "items": string, "description": "Names of other components this one calls or is called by"]
            ])),
            "executionFlow": array(object([
                "step": ["type": "string", "description": "Short step label, e.g. '1. Launch'"],
                "description": string,
                "files": strings
            ])),
            "dataFlow": ["type": "string", "description": "Markdown describing how data moves through the system: inputs, storage, transformations, outputs"],
            "externalDependencies": array(object(["name": string, "purpose": string])),
            "buildAndRun": ["type": "string", "description": "Markdown: how to build, run and test the project"],
            "concerns": array(object([
                "title": string,
                "severity": ["type": "string", "enum": ["low", "medium", "high"]],
                "detail": string,
                "files": strings
            ])),
            "optimizationOpportunities": array(object([
                "title": string,
                "category": ["type": "string", "enum": ["performance", "memory", "readability", "architecture", "security", "reliability", "testing", "dependencies", "concurrency", "other"]],
                "impact": ["type": "string", "enum": ["low", "medium", "high"]],
                "effort": ["type": "string", "enum": ["low", "medium", "high"]],
                "detail": string,
                "files": strings,
                "suggestedPrompt": ["type": "string", "description": "A ready-to-use instruction the user can give CodeScope's optimizer to carry out this improvement"]
            ])),
            "glossary": array(object(["term": string, "meaning": string]))
        ])
    }()
}
