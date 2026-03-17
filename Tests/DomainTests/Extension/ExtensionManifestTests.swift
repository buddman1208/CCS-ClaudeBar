import Foundation
import Testing
@testable import Domain

@Suite
struct ExtensionManifestTests {
    // MARK: - Parsing from JSON

    @Test
    func `parses minimal manifest with single section`() throws {
        let json = """
        {
            "id": "my-provider",
            "name": "My Provider",
            "version": "1.0.0",
            "sections": [
                {
                    "id": "quotas",
                    "type": "quotaGrid",
                    "probe": { "command": "./probe.sh" }
                }
            ]
        }
        """

        let manifest = try ExtensionManifest.parse(from: json.data(using: .utf8)!)

        #expect(manifest.id == "my-provider")
        #expect(manifest.name == "My Provider")
        #expect(manifest.version == "1.0.0")
        #expect(manifest.sections.count == 1)
        #expect(manifest.sections[0].id == "quotas")
        #expect(manifest.sections[0].type == .quotaGrid)
        #expect(manifest.sections[0].probeCommand == "./probe.sh")
    }

    @Test
    func `parses full manifest with all optional fields`() throws {
        let json = """
        {
            "id": "openrouter",
            "name": "OpenRouter",
            "version": "2.0.0",
            "description": "Monitor OpenRouter credits",
            "icon": "network",
            "colors": {
                "primary": "#6366F1",
                "gradient": ["#6366F1", "#8B5CF6"]
            },
            "dashboardURL": "https://openrouter.ai/activity",
            "statusPageURL": "https://status.openrouter.ai",
            "sections": [
                {
                    "id": "status",
                    "type": "statusBanner",
                    "probe": { "command": "./probe-status.sh", "interval": 30, "timeout": 5 }
                },
                {
                    "id": "quotas",
                    "type": "quotaGrid",
                    "probe": { "command": "./probe-quota.sh", "interval": 60 }
                },
                {
                    "id": "daily",
                    "type": "dailyUsage",
                    "probe": { "command": "./probe-daily.sh", "interval": 300 }
                },
                {
                    "id": "custom",
                    "type": "metricsRow",
                    "probe": { "command": "./probe-metrics.sh", "interval": 120 }
                }
            ]
        }
        """

        let manifest = try ExtensionManifest.parse(from: json.data(using: .utf8)!)

        #expect(manifest.id == "openrouter")
        #expect(manifest.name == "OpenRouter")
        #expect(manifest.version == "2.0.0")
        #expect(manifest.description == "Monitor OpenRouter credits")
        #expect(manifest.icon == "network")
        #expect(manifest.colors?.primary == "#6366F1")
        #expect(manifest.colors?.gradient == ["#6366F1", "#8B5CF6"])
        #expect(manifest.dashboardURL == URL(string: "https://openrouter.ai/activity"))
        #expect(manifest.statusPageURL == URL(string: "https://status.openrouter.ai"))
        #expect(manifest.sections.count == 4)
    }

    @Test
    func `parses section probe defaults`() throws {
        let json = """
        {
            "id": "test",
            "name": "Test",
            "version": "1.0.0",
            "sections": [
                {
                    "id": "main",
                    "type": "quotaGrid",
                    "probe": { "command": "./probe.sh" }
                }
            ]
        }
        """

        let manifest = try ExtensionManifest.parse(from: json.data(using: .utf8)!)
        let section = manifest.sections[0]

        // Default interval is 60 seconds
        #expect(section.refreshInterval == 60)
        // Default timeout is 10 seconds
        #expect(section.timeout == 10)
    }

    @Test
    func `parses section with custom interval and timeout`() throws {
        let json = """
        {
            "id": "test",
            "name": "Test",
            "version": "1.0.0",
            "sections": [
                {
                    "id": "heavy",
                    "type": "dailyUsage",
                    "probe": { "command": "./probe.sh", "interval": 300, "timeout": 30 }
                }
            ]
        }
        """

        let manifest = try ExtensionManifest.parse(from: json.data(using: .utf8)!)
        let section = manifest.sections[0]

        #expect(section.refreshInterval == 300)
        #expect(section.timeout == 30)
    }

    @Test
    func `throws on missing required fields`() {
        let json = """
        {
            "name": "Missing ID",
            "version": "1.0.0",
            "sections": []
        }
        """

        #expect(throws: (any Error).self) {
            try ExtensionManifest.parse(from: json.data(using: .utf8)!)
        }
    }

    @Test
    func `throws on empty sections array`() {
        let json = """
        {
            "id": "test",
            "name": "Test",
            "version": "1.0.0",
            "sections": []
        }
        """

        #expect(throws: ExtensionManifestError.self) {
            try ExtensionManifest.parse(from: json.data(using: .utf8)!)
        }
    }

    @Test
    func `throws on unknown section type`() {
        let json = """
        {
            "id": "test",
            "name": "Test",
            "version": "1.0.0",
            "sections": [
                {
                    "id": "bad",
                    "type": "unknownType",
                    "probe": { "command": "./probe.sh" }
                }
            ]
        }
        """

        #expect(throws: (any Error).self) {
            try ExtensionManifest.parse(from: json.data(using: .utf8)!)
        }
    }

    // MARK: - Section Types

    @Test
    func `all section types parse correctly`() throws {
        let types: [(String, SectionType)] = [
            ("quotaGrid", .quotaGrid),
            ("costUsage", .costUsage),
            ("dailyUsage", .dailyUsage),
            ("metricsRow", .metricsRow),
            ("statusBanner", .statusBanner),
            ("healthCheck", .healthCheck),
        ]

        for (jsonValue, expected) in types {
            let json = """
            {
                "id": "test",
                "name": "Test",
                "version": "1.0.0",
                "sections": [
                    {
                        "id": "s1",
                        "type": "\(jsonValue)",
                        "probe": { "command": "./probe.sh" }
                    }
                ]
            }
            """

            let manifest = try ExtensionManifest.parse(from: json.data(using: .utf8)!)
            #expect(manifest.sections[0].type == expected, "Expected \(expected) for '\(jsonValue)'")
        }
    }

    // MARK: - Built-in Health Check Probe

    @Test
    func `parses healthCheck builtIn probe config`() throws {
        let json = """
        {
            "id": "my-api",
            "name": "My API",
            "version": "1.0.0",
            "sections": [
                {
                    "id": "health",
                    "type": "healthCheck",
                    "probe": {
                        "builtIn": "healthCheck",
                        "url": "https://api.example.com/health",
                        "interval": 30
                    }
                }
            ]
        }
        """

        let manifest = try ExtensionManifest.parse(from: json.data(using: .utf8)!)
        let section = manifest.sections[0]

        #expect(section.type == .healthCheck)
        #expect(section.probeConfig == .healthCheck(url: URL(string: "https://api.example.com/health")!))
        #expect(section.refreshInterval == 30)
        #expect(section.probeCommand == "")
    }

    @Test
    func `parses mixed script and healthCheck sections`() throws {
        let json = """
        {
            "id": "mixed",
            "name": "Mixed",
            "version": "1.0.0",
            "sections": [
                {
                    "id": "health",
                    "type": "healthCheck",
                    "probe": { "builtIn": "healthCheck", "url": "https://example.com/ping" }
                },
                {
                    "id": "quotas",
                    "type": "quotaGrid",
                    "probe": { "command": "./probe.sh" }
                }
            ]
        }
        """

        let manifest = try ExtensionManifest.parse(from: json.data(using: .utf8)!)

        #expect(manifest.sections[0].probeConfig == .healthCheck(url: URL(string: "https://example.com/ping")!))
        #expect(manifest.sections[1].probeConfig == .script("./probe.sh"))
    }

    @Test
    func `throws on builtIn probe without url`() {
        let json = """
        {
            "id": "test",
            "name": "Test",
            "version": "1.0.0",
            "sections": [
                {
                    "id": "health",
                    "type": "healthCheck",
                    "probe": { "builtIn": "healthCheck" }
                }
            ]
        }
        """

        #expect(throws: ExtensionManifestError.self) {
            try ExtensionManifest.parse(from: json.data(using: .utf8)!)
        }
    }
}