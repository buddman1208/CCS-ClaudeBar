import Foundation
import Testing
@testable import Domain

@Suite
struct ConfigFieldTests {
    // MARK: - JSON Decoding

    @Test
    func `decodes minimal config field with only required properties`() throws {
        let json = """
        { "id": "apiKey", "label": "API Key", "type": "string" }
        """

        let field = try JSONDecoder().decode(ConfigField.self, from: json.data(using: .utf8)!)

        #expect(field.id == "apiKey")
        #expect(field.label == "API Key")
        #expect(field.type == .string)
        #expect(field.required == false)
        #expect(field.defaultValue == nil)
        #expect(field.placeholder == nil)
        #expect(field.helpText == nil)
        #expect(field.options == nil)
    }

    @Test
    func `decodes full config field with all optional properties`() throws {
        let json = """
        {
            "id": "region",
            "label": "Region",
            "type": "choice",
            "required": true,
            "default": "us-east-1",
            "placeholder": "Select region",
            "helpText": "AWS region for API calls",
            "options": ["us-east-1", "eu-west-1", "ap-southeast-1"]
        }
        """

        let field = try JSONDecoder().decode(ConfigField.self, from: json.data(using: .utf8)!)

        #expect(field.id == "region")
        #expect(field.label == "Region")
        #expect(field.type == .choice)
        #expect(field.required == true)
        #expect(field.defaultValue == "us-east-1")
        #expect(field.placeholder == "Select region")
        #expect(field.helpText == "AWS region for API calls")
        #expect(field.options == ["us-east-1", "eu-west-1", "ap-southeast-1"])
    }

    // MARK: - Field Types

    @Test
    func `decodes all field types`() throws {
        let types: [(String, ConfigFieldType)] = [
            ("string", .string),
            ("secret", .secret),
            ("number", .number),
            ("toggle", .toggle),
            ("choice", .choice),
            ("path", .path),
        ]

        for (jsonValue, expected) in types {
            let json = """
            { "id": "f", "label": "F", "type": "\(jsonValue)" }
            """
            let field = try JSONDecoder().decode(ConfigField.self, from: json.data(using: .utf8)!)
            #expect(field.type == expected, "Expected \(expected) for '\(jsonValue)'")
        }
    }

    // MARK: - Environment Variable Name

    @Test
    func `computes environment variable name from camelCase id`() {
        let field = ConfigField(id: "apiKey", label: "API Key", type: .secret)
        #expect(field.environmentVariableName == "CLAUDEBAR_API_KEY")
    }

    @Test
    func `computes environment variable name from simple id`() {
        let field = ConfigField(id: "port", label: "Port", type: .number)
        #expect(field.environmentVariableName == "CLAUDEBAR_PORT")
    }

    @Test
    func `computes environment variable name from kebab-case id`() {
        let field = ConfigField(id: "base-url", label: "Base URL", type: .string)
        #expect(field.environmentVariableName == "CLAUDEBAR_BASE_URL")
    }

    @Test
    func `computes environment variable name from snake_case id`() {
        let field = ConfigField(id: "monthly_budget", label: "Budget", type: .number)
        #expect(field.environmentVariableName == "CLAUDEBAR_MONTHLY_BUDGET")
    }

    // MARK: - Secret Detection

    @Test
    func `secret type fields are identified as sensitive`() {
        let field = ConfigField(id: "token", label: "Token", type: .secret)
        #expect(field.isSecret == true)
    }

    @Test
    func `non-secret type fields are not sensitive`() {
        let field = ConfigField(id: "url", label: "URL", type: .string)
        #expect(field.isSecret == false)
    }

    // MARK: - Effective Value

    @Test
    func `effectiveValue returns stored value when present`() {
        let field = ConfigField(id: "url", label: "URL", type: .string, defaultValue: "https://default.com")
        #expect(field.effectiveValue(stored: "https://custom.com") == "https://custom.com")
    }

    @Test
    func `effectiveValue falls back to default when no stored value`() {
        let field = ConfigField(id: "url", label: "URL", type: .string, defaultValue: "https://default.com")
        #expect(field.effectiveValue(stored: nil) == "https://default.com")
    }

    @Test
    func `effectiveValue returns nil when no stored value and no default`() {
        let field = ConfigField(id: "url", label: "URL", type: .string)
        #expect(field.effectiveValue(stored: nil) == nil)
    }
}
