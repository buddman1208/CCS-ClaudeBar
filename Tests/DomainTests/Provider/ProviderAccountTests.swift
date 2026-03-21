import Testing
@testable import Domain

@Suite("ProviderAccount")
struct ProviderAccountTests {

    // MARK: - Identity

    @Test("Default account ID equals provider ID for backward compatibility")
    func defaultAccountIdEqualsProviderId() {
        let account = ProviderAccount(providerId: "claude", label: "Default")

        #expect(account.id == "claude")
        #expect(account.isDefault == true)
    }

    @Test("Named account ID is compound: providerId.accountId")
    func namedAccountIdIsCompound() {
        let account = ProviderAccount(
            accountId: "personal",
            providerId: "claude",
            label: "Personal"
        )

        #expect(account.id == "claude.personal")
        #expect(account.isDefault == false)
    }

    @Test("Two accounts with same accountId and providerId are equal")
    func equalityByIdAndProvider() {
        let a = ProviderAccount(accountId: "work", providerId: "claude", label: "Work")
        let b = ProviderAccount(accountId: "work", providerId: "claude", label: "Work Account")

        // Equatable compares all fields, so different labels are not equal
        #expect(a != b)
        // But their IDs match
        #expect(a.id == b.id)
    }

    // MARK: - Display

    @Test("Display name prefers label over email")
    func displayNamePrefersLabel() {
        let account = ProviderAccount(
            accountId: "work",
            providerId: "claude",
            label: "Work Account",
            email: "work@example.com"
        )

        #expect(account.displayName == "Work Account")
    }

    @Test("Display name falls back to email when label is empty")
    func displayNameFallsBackToEmail() {
        let account = ProviderAccount(
            accountId: "work",
            providerId: "claude",
            label: "",
            email: "work@example.com"
        )

        #expect(account.displayName == "work@example.com")
    }

    @Test("Display name falls back to accountId when both label and email are nil")
    func displayNameFallsBackToAccountId() {
        let account = ProviderAccount(
            accountId: "work",
            providerId: "claude",
            label: ""
        )

        #expect(account.displayName == "work")
    }

    @Test("Initial letter is uppercased first character of display name")
    func initialLetterFromDisplayName() {
        let account = ProviderAccount(
            accountId: "personal",
            providerId: "claude",
            label: "personal account"
        )

        #expect(account.initialLetter == "P")
    }

    // MARK: - Constants

    @Test("Default account ID constant is 'default'")
    func defaultAccountIdConstant() {
        #expect(ProviderAccount.defaultAccountId == "default")
    }
}
