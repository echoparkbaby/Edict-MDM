import Testing
@testable import BlueConnectAdmin

/// `MunkiRepoStore.catalogURL` is what the Settings → Munki Repo pane
/// previews live, and what every catalog fetch ends up hitting. The
/// composition rules ("strip schemes, trim slashes, percent-encode the
/// key path") are easy to get wrong on a refactor, hence these tests.
// `MunkiRepoStore` is @MainActor-isolated, so its static URL helper
// inherits that isolation in Swift 5 + Sendable strict checking.
// Marking the suite @MainActor lets us call the helper synchronously.
@MainActor
@Suite("MunkiRepoStore.catalogURL composition")
struct MunkiRepoStoreTests {

    // (endpoint, bucket, prefix, key, expected)
    @Test(arguments: [
        // endpoint only → just prepend the scheme
        ("munki.example.com", "", "", "catalogs/all",
         "https://munki.example.com/catalogs/all"),
        // bucket + prefix get appended in order
        ("s3.us-east-1.wasabisys.com", "my-bucket", "munki_repo", "catalogs/all",
         "https://s3.us-east-1.wasabisys.com/my-bucket/munki_repo/catalogs/all"),
        // an explicit scheme on the endpoint is stripped, not duplicated
        ("https://munki.example.com/", "", "", "catalogs/all",
         "https://munki.example.com/catalogs/all"),
        // leading/trailing slashes on bucket + prefix are trimmed
        ("munki.example.com", "/bucket/", "/repo/", "catalogs/all",
         "https://munki.example.com/bucket/repo/catalogs/all"),
        // spaces in the key → %20, but path separators stay as `/`
        ("munki.example.com", "", "", "pkgs/A Better Finder Rename/abfr.dmg",
         "https://munki.example.com/pkgs/A%20Better%20Finder%20Rename/abfr.dmg"),
    ])
    func catalogURLComposition(endpoint: String, bucket: String, prefix: String,
                               key: String, expected: String) {
        let url = MunkiRepoStore.catalogURL(endpoint: endpoint, bucket: bucket, prefix: prefix, key: key)
        #expect(url == expected)
    }
}
