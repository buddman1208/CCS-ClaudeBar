import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

@Suite("CCSAccountsLoader Tests")
struct CCSAccountsLoaderTests {

    // MARK: - Helpers

    private func makeTempHome() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccs-loader-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func writeAccountsJSON(at home: URL, body: String) throws {
        let cliproxy = home.appendingPathComponent(".ccs/cliproxy", isDirectory: true)
        try FileManager.default.createDirectory(at: cliproxy, withIntermediateDirectories: true)
        try body.write(to: cliproxy.appendingPathComponent("accounts.json"), atomically: true, encoding: .utf8)
    }

    private func writeAuthFile(at home: URL, named name: String, body: String) throws {
        let auth = home.appendingPathComponent(".ccs/cliproxy/auth", isDirectory: true)
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        try body.write(to: auth.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func sampleAccountsJSON() -> String {
        """
        {
          "version": 1,
          "providers": {
            "claude": {
              "default": "primary@example.com",
              "accounts": {
                "primary@example.com": {
                  "email": "primary@example.com",
                  "nickname": "primary",
                  "tokenFile": "claude-primary@example.com.json",
                  "createdAt": "2026-04-22T17:52:15.513Z",
                  "lastUsedAt": "2026-04-24T15:25:02.878Z"
                },
                "secondary@example.com": {
                  "email": "secondary@example.com",
                  "nickname": "secondary",
                  "tokenFile": "claude-secondary@example.com.json",
                  "paused": true
                }
              }
            },
            "codex": {
              "default": "user@example.com",
              "accounts": {
                "user@example.com": {
                  "email": "user@example.com",
                  "nickname": "user",
                  "tokenFile": "codex-user@example.com-pro.json"
                }
              }
            }
          }
        }
        """
    }

    // MARK: - hasAccountsFile

    @Test
    func `hasAccountsFile returns false when CCS not installed`() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let loader = CCSAccountsLoader(homeDirectory: home)
        #expect(loader.hasAccountsFile() == false)
    }

    @Test
    func `hasAccountsFile returns true when accounts json exists`() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeAccountsJSON(at: home, body: sampleAccountsJSON())

        let loader = CCSAccountsLoader(homeDirectory: home)
        #expect(loader.hasAccountsFile() == true)
    }

    // MARK: - loadAccounts

    @Test
    func `loadAccounts returns empty when CCS not installed`() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let loader = CCSAccountsLoader(homeDirectory: home)

        #expect(loader.loadAccounts(provider: .claude).isEmpty)
        #expect(loader.loadAccounts(provider: .codex).isEmpty)
    }

    @Test
    func `loadAccounts decodes claude accounts and marks default`() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeAccountsJSON(at: home, body: sampleAccountsJSON())

        let loader = CCSAccountsLoader(homeDirectory: home)
        let accounts = loader.loadAccounts(provider: .claude)

        #expect(accounts.count == 2)
        // Default first
        #expect(accounts.first?.email == "primary@example.com")
        #expect(accounts.first?.isDefault == true)
        let secondary = accounts.first { $0.email == "secondary@example.com" }
        #expect(secondary?.paused == true)
        #expect(secondary?.isDefault == false)
    }

    @Test
    func `loadAccounts decodes codex accounts`() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeAccountsJSON(at: home, body: sampleAccountsJSON())

        let loader = CCSAccountsLoader(homeDirectory: home)
        let accounts = loader.loadAccounts(provider: .codex)

        #expect(accounts.count == 1)
        #expect(accounts.first?.email == "user@example.com")
        #expect(accounts.first?.tokenFile == "codex-user@example.com-pro.json")
    }

    @Test
    func `loadAccounts returns empty for malformed json`() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeAccountsJSON(at: home, body: "{not valid json")

        let loader = CCSAccountsLoader(homeDirectory: home)
        #expect(loader.loadAccounts(provider: .claude).isEmpty)
    }

    // MARK: - loadToken

    @Test
    func `loadToken returns claude token`() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeAccountsJSON(at: home, body: sampleAccountsJSON())
        try writeAuthFile(
            at: home,
            named: "claude-primary@example.com.json",
            body: """
            {"access_token":"sk-ant-oat01-token","refresh_token":"sk-ant-ort01-rfsh","email":"primary@example.com","expired":"2099-01-01T00:00:00Z","type":"claude"}
            """
        )

        let loader = CCSAccountsLoader(homeDirectory: home)
        let account = loader.loadAccounts(provider: .claude).first { $0.email == "primary@example.com" }!
        let token = loader.loadToken(for: account)

        #expect(token != nil)
        #expect(token?.kind == .claude)
        #expect(token?.accessToken == "sk-ant-oat01-token")
        #expect(token?.refreshToken == "sk-ant-ort01-rfsh")
        #expect(token?.isExpired == false)
    }

    @Test
    func `loadToken returns codex token with account_id`() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeAccountsJSON(at: home, body: sampleAccountsJSON())
        try writeAuthFile(
            at: home,
            named: "codex-user@example.com-pro.json",
            body: """
            {"access_token":"jwt.token.here","account_id":"acct_abc","expired":"2099-01-01T00:00:00Z"}
            """
        )

        let loader = CCSAccountsLoader(homeDirectory: home)
        let account = loader.loadAccounts(provider: .codex).first!
        let token = loader.loadToken(for: account)

        #expect(token?.kind == .codex)
        #expect(token?.accessToken == "jwt.token.here")
        #expect(token?.accountId == "acct_abc")
    }

    @Test
    func `loadToken returns nil when token file missing`() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeAccountsJSON(at: home, body: sampleAccountsJSON())

        let loader = CCSAccountsLoader(homeDirectory: home)
        let account = loader.loadAccounts(provider: .claude).first { $0.email == "primary@example.com" }!
        let token = loader.loadToken(for: account)

        #expect(token == nil)
    }

    @Test
    func `loadToken marks expired tokens`() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeAccountsJSON(at: home, body: sampleAccountsJSON())
        try writeAuthFile(
            at: home,
            named: "claude-primary@example.com.json",
            body: """
            {"access_token":"sk-ant-oat01-token","refresh_token":"sk-ant-ort01-rfsh","email":"primary@example.com","expired":"2000-01-01T00:00:00Z","type":"claude"}
            """
        )

        let loader = CCSAccountsLoader(homeDirectory: home)
        let account = loader.loadAccounts(provider: .claude).first { $0.email == "primary@example.com" }!
        let token = loader.loadToken(for: account)

        #expect(token?.isExpired == true)
    }
}
