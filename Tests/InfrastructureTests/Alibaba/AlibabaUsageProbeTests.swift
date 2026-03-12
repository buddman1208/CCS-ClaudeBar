import Testing
import Foundation
import Mockable
@testable import Infrastructure
@testable import Domain

@Suite
struct AlibabaUsageProbeTests {

    // MARK: - Sample Response

    static let sampleSuccessResponse = """
    {
      "code": "200",
      "data": {
        "codingPlanInstanceInfos": [
          {
            "planName": "Test Plan",
            "status": "VALID",
            "codingPlanQuotaInfo": {
              "per5HourUsedQuota": 10,
              "per5HourTotalQuota": 100,
              "perWeekUsedQuota": 50,
              "perWeekTotalQuota": 500,
              "perBillMonthUsedQuota": 100,
              "perBillMonthTotalQuota": 2000
            }
          }
        ]
      },
      "success": true
    }
    """

    private func makeSettingsRepository() -> UserDefaultsProviderSettingsRepository {
        let suiteName = "com.claudebar.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let repo = UserDefaultsProviderSettingsRepository(userDefaults: defaults)
        repo.setEnabled(true, forProvider: "alibaba")
        return repo
    }

    private func makeNoOpCookieProvider() -> MockAlibabaCookieProviding {
        let mock = MockAlibabaCookieProviding()
        given(mock).extractBrowserCookies().willReturn(nil)
        return mock
    }

    private func mockSuccessResponse() -> (Data, URLResponse) {
        let data = Data(Self.sampleSuccessResponse.utf8)
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    // MARK: - isAvailable

    @Test
    func `isAvailable returns false when no cookie and no API key`() async {
        let repo = makeSettingsRepository()
        repo.setAlibabaCookieSource(.manual)

        let probe = AlibabaUsageProbe(settingsRepository: repo, cookieProvider: makeNoOpCookieProvider())

        let available = await probe.isAvailable()
        #expect(available == false)
    }

    @Test
    func `isAvailable returns true when API key is set`() async {
        let repo = makeSettingsRepository()
        repo.saveAlibabaApiKey("sk-test-key-123")

        let probe = AlibabaUsageProbe(settingsRepository: repo, cookieProvider: makeNoOpCookieProvider())

        let available = await probe.isAvailable()
        #expect(available == true)
    }

    @Test
    func `isAvailable returns true when manual cookie is set`() async {
        let repo = makeSettingsRepository()
        repo.setAlibabaCookieSource(.manual)
        repo.saveAlibabaManualCookie("login_aliyunid_ticket=abc123")

        let probe = AlibabaUsageProbe(settingsRepository: repo, cookieProvider: makeNoOpCookieProvider())

        let available = await probe.isAvailable()
        #expect(available == true)
    }

    @Test
    func `isAvailable returns false for auto cookie source without browser cookies`() async {
        let repo = makeSettingsRepository()
        repo.setAlibabaCookieSource(.auto)

        let probe = AlibabaUsageProbe(settingsRepository: repo, cookieProvider: makeNoOpCookieProvider())

        let available = await probe.isAvailable()
        #expect(available == false)
    }

    @Test
    func `isAvailable returns false when API key is empty string`() async {
        let repo = makeSettingsRepository()
        repo.saveAlibabaApiKey("")

        let probe = AlibabaUsageProbe(settingsRepository: repo, cookieProvider: makeNoOpCookieProvider())

        let available = await probe.isAvailable()
        #expect(available == false)
    }

    // MARK: - probe() with API key

    @Test
    func `probe with API key returns snapshot on success`() async throws {
        let repo = makeSettingsRepository()
        repo.saveAlibabaApiKey("sk-test-key")
        repo.setAlibabaRegion(.international)

        let mockNetwork = MockNetworkClient()
        given(mockNetwork).request(.any).willReturn(mockSuccessResponse())

        let probe = AlibabaUsageProbe(settingsRepository: repo, networkClient: mockNetwork, cookieProvider: makeNoOpCookieProvider())

        let snapshot = try await probe.probe()
        #expect(snapshot.providerId == "alibaba")
        #expect(snapshot.quotas.count == 3)
        #expect(snapshot.quota(for: .session)?.percentRemaining == 90.0)
    }

    @Test
    func `probe with API key throws authenticationRequired on 401`() async throws {
        let repo = makeSettingsRepository()
        repo.saveAlibabaApiKey("sk-bad-key")

        let mockNetwork = MockNetworkClient()
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        given(mockNetwork).request(.any).willReturn((Data(), response))

        let probe = AlibabaUsageProbe(settingsRepository: repo, networkClient: mockNetwork, cookieProvider: makeNoOpCookieProvider())

        do {
            _ = try await probe.probe()
            Issue.record("Expected authenticationRequired error")
        } catch {
            #expect(error as? ProbeError == .authenticationRequired)
        }
    }

    @Test
    func `probe with API key throws authenticationRequired on 403`() async throws {
        let repo = makeSettingsRepository()
        repo.saveAlibabaApiKey("sk-forbidden")

        let mockNetwork = MockNetworkClient()
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        given(mockNetwork).request(.any).willReturn((Data(), response))

        let probe = AlibabaUsageProbe(settingsRepository: repo, networkClient: mockNetwork, cookieProvider: makeNoOpCookieProvider())

        do {
            _ = try await probe.probe()
            Issue.record("Expected authenticationRequired error")
        } catch {
            #expect(error as? ProbeError == .authenticationRequired)
        }
    }

    @Test
    func `probe with API key throws executionFailed on 500`() async throws {
        let repo = makeSettingsRepository()
        repo.saveAlibabaApiKey("sk-test")

        let mockNetwork = MockNetworkClient()
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 500, httpVersion: nil, headerFields: nil)!
        given(mockNetwork).request(.any).willReturn((Data(), response))

        let probe = AlibabaUsageProbe(settingsRepository: repo, networkClient: mockNetwork, cookieProvider: makeNoOpCookieProvider())

        do {
            _ = try await probe.probe()
            Issue.record("Expected ProbeError")
        } catch {
            #expect(error is ProbeError)
        }
    }

    @Test
    func `probe uses china region when configured`() async throws {
        let repo = makeSettingsRepository()
        repo.saveAlibabaApiKey("sk-cn-key")
        repo.setAlibabaRegion(.chinaMainland)

        let mockNetwork = MockNetworkClient()
        given(mockNetwork).request(.any).willReturn(mockSuccessResponse())

        let probe = AlibabaUsageProbe(settingsRepository: repo, networkClient: mockNetwork, cookieProvider: makeNoOpCookieProvider())

        let snapshot = try await probe.probe()
        #expect(snapshot.quotas.count == 3)
    }

    // MARK: - probe() with manual cookie

    @Test
    func `probe with manual cookie and sec_token in cookie succeeds`() async throws {
        let repo = makeSettingsRepository()
        repo.setAlibabaCookieSource(.manual)
        repo.saveAlibabaManualCookie("login_aliyunid_ticket=abc; sec_token=my_sec_token; login_aliyunid_csrf=csrf123")

        let mockNetwork = MockNetworkClient()
        given(mockNetwork).request(.any).willReturn(mockSuccessResponse())

        let probe = AlibabaUsageProbe(settingsRepository: repo, networkClient: mockNetwork, cookieProvider: makeNoOpCookieProvider())

        let snapshot = try await probe.probe()
        #expect(snapshot.providerId == "alibaba")
        #expect(snapshot.quotas.count == 3)
    }

    @Test
    func `probe with cookie throws sessionExpired on 403`() async throws {
        let repo = makeSettingsRepository()
        repo.setAlibabaCookieSource(.manual)
        repo.saveAlibabaManualCookie("login_aliyunid_ticket=abc; sec_token=old_token")

        let mockNetwork = MockNetworkClient()
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        given(mockNetwork).request(.any).willReturn((Data(), response))

        let probe = AlibabaUsageProbe(settingsRepository: repo, networkClient: mockNetwork, cookieProvider: makeNoOpCookieProvider())

        do {
            _ = try await probe.probe()
            Issue.record("Expected sessionExpired error")
        } catch {
            #expect(error as? ProbeError == .sessionExpired())
        }
    }

    @Test
    func `probe with empty manual cookie throws authenticationRequired`() async throws {
        let repo = makeSettingsRepository()
        repo.setAlibabaCookieSource(.manual)

        let probe = AlibabaUsageProbe(settingsRepository: repo, cookieProvider: makeNoOpCookieProvider())

        do {
            _ = try await probe.probe()
            Issue.record("Expected authenticationRequired error")
        } catch {
            #expect(error as? ProbeError == .authenticationRequired)
        }
    }

    @Test
    func `probe with auto cookie source throws authenticationRequired`() async throws {
        let repo = makeSettingsRepository()
        repo.setAlibabaCookieSource(.auto)

        let probe = AlibabaUsageProbe(settingsRepository: repo, cookieProvider: makeNoOpCookieProvider())

        do {
            _ = try await probe.probe()
            Issue.record("Expected authenticationRequired error")
        } catch {
            #expect(error as? ProbeError == .authenticationRequired)
        }
    }

    // MARK: - URL Construction

    @Test
    func `apiQuotaURL uses international gateway for intl region`() {
        let url = AlibabaUsageProbe.apiQuotaURL(for: .international)
        #expect(url.absoluteString.contains("modelstudio.console.alibabacloud.com"))
        #expect(url.absoluteString.contains("api.json"))
    }

    @Test
    func `apiQuotaURL uses china gateway for cn region`() {
        let url = AlibabaUsageProbe.apiQuotaURL(for: .chinaMainland)
        #expect(url.absoluteString.contains("bailian.console.aliyun.com"))
    }

    @Test
    func `consoleRPCURL uses singapore host for intl region`() {
        let url = AlibabaUsageProbe.consoleRPCURL(for: .international)
        #expect(url.absoluteString.contains("bailian-singapore-cs"))
    }

    @Test
    func `consoleRPCURL uses beijing host for cn region`() {
        let url = AlibabaUsageProbe.consoleRPCURL(for: .chinaMainland)
        #expect(url.absoluteString.contains("bailian-beijing-cs"))
    }

    @Test
    func `apiRequestBody contains commodity code`() throws {
        let body = AlibabaUsageProbe.apiRequestBody(for: .international)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let request = json?["queryCodingPlanInstanceInfoRequest"] as? [String: Any]
        #expect(request?["commodityCode"] as? String == "sfm_codingplan_public_intl")
    }

    @Test
    func `apiRequestBody contains china commodity code for cn region`() throws {
        let body = AlibabaUsageProbe.apiRequestBody(for: .chinaMainland)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let request = json?["queryCodingPlanInstanceInfoRequest"] as? [String: Any]
        #expect(request?["commodityCode"] as? String == "sfm_codingplan_public_cn")
    }

    @Test
    func `consoleRequestBody contains sec_token and region`() {
        let body = AlibabaUsageProbe.consoleRequestBody(for: .chinaMainland, secToken: "test_token")
        let bodyString = String(data: body, encoding: .utf8) ?? ""
        #expect(bodyString.contains("sec_token=test_token"))
        #expect(bodyString.contains("region=cn-beijing"))
    }

    // MARK: - Cookie Helpers

    @Test
    func `extractCookieValue finds named cookie`() {
        let cookie = "a=1; login_ticket=abc123; b=2"
        let value = AlibabaUsageProbe.extractCookieValue(name: "login_ticket", from: cookie)
        #expect(value == "abc123")
    }

    @Test
    func `extractCookieValue returns nil for missing cookie`() {
        let cookie = "a=1; b=2"
        let value = AlibabaUsageProbe.extractCookieValue(name: "missing", from: cookie)
        #expect(value == nil)
    }

    @Test
    func `extractCookieValue handles cookie with equals in value`() {
        let cookie = "token=abc=def=ghi; other=1"
        let value = AlibabaUsageProbe.extractCookieValue(name: "token", from: cookie)
        #expect(value == "abc=def=ghi")
    }

    // MARK: - SEC Token Extraction from HTML

    @Test
    func `extractSecTokenFromHTML finds JSON style token`() {
        let html = #"<script>var config = {"sec_token":"my_token_123","other":"value"};</script>"#
        let token = AlibabaUsageProbe.extractSecTokenFromHTML(html)
        #expect(token == "my_token_123")
    }

    @Test
    func `extractSecTokenFromHTML finds single-quote assignment`() {
        let html = "<script>sec_token = 'token_456';</script>"
        let token = AlibabaUsageProbe.extractSecTokenFromHTML(html)
        #expect(token == "token_456")
    }

    @Test
    func `extractSecTokenFromHTML finds double-quote assignment`() {
        let html = #"<script>sec_token = "token_789";</script>"#
        let token = AlibabaUsageProbe.extractSecTokenFromHTML(html)
        #expect(token == "token_789")
    }

    @Test
    func `extractSecTokenFromHTML returns nil when not found`() {
        let html = "<html><body>No token here</body></html>"
        let token = AlibabaUsageProbe.extractSecTokenFromHTML(html)
        #expect(token == nil)
    }

    // MARK: - AlibabaRegion Properties

    @Test
    func `international region has correct properties`() {
        let region = AlibabaRegion.international
        #expect(region.displayName == "International")
        #expect(region.gatewayBaseURLString == "https://modelstudio.console.alibabacloud.com")
        #expect(region.currentRegionID == "ap-southeast-1")
        #expect(region.commodityCode == "sfm_codingplan_public_intl")
        #expect(region.consoleRPCAction == "IntlBroadScopeAspnGateway")
    }

    @Test
    func `china region has correct properties`() {
        let region = AlibabaRegion.chinaMainland
        #expect(region.displayName == "China Mainland")
        #expect(region.gatewayBaseURLString == "https://bailian.console.aliyun.com")
        #expect(region.currentRegionID == "cn-beijing")
        #expect(region.commodityCode == "sfm_codingplan_public_cn")
        #expect(region.consoleRPCAction == "BroadScopeAspnGateway")
    }

    @Test
    func `region dashboardURL is valid`() {
        #expect(AlibabaRegion.international.dashboardURL.absoluteString.contains("alibabacloud.com"))
        #expect(AlibabaRegion.chinaMainland.dashboardURL.absoluteString.contains("aliyun.com"))
    }

    @Test
    func `region consoleRPCBaseURLString is correct`() {
        #expect(AlibabaRegion.international.consoleRPCBaseURLString.contains("singapore"))
        #expect(AlibabaRegion.chinaMainland.consoleRPCBaseURLString.contains("beijing"))
    }

    // MARK: - AlibabaCookieSource

    @Test
    func `cookie source display names are set`() {
        #expect(AlibabaCookieSource.auto.displayName == "Auto (from browser)")
        #expect(AlibabaCookieSource.manual.displayName == "Manual")
    }
}
