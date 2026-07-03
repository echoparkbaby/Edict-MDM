import Testing
@testable import BlueConnectAdmin

/// Credentials must reach curl through a `--config -` stdin file, never on
/// argv (where `ps -ww` exposes them). These pin that the secret-bearing
/// values land in the config string and never in the argument array.
@Suite("curl credential handling")
struct CurlConfigTests {

    // MARK: CurlConfig escaping

    @Test func escapeHandlesQuotesAndBackslashes() {
        #expect(CurlConfig.escape(#"a"b\c"#) == #"a\"b\\c"#)
    }

    @Test func userLineFormats() {
        #expect(CurlConfig.userLine(user: "u", password: "p") == "user = \"u:p\"\n")
    }

    // MARK: MunkiRepoStore.curlAuth

    @Test func s3ModeKeepsSecretKeyOutOfArgs() {
        let auth = MunkiRepoStore.curlAuth(mode: "s3", basicUser: "", basicPassword: "",
                                           accessKey: "AKIA", secretKey: "TOPSECRET", region: "us-east-1")
        let argstr = auth.args.joined(separator: " ")
        #expect(argstr.contains("--aws-sigv4"))
        #expect(!argstr.contains("TOPSECRET"))
        #expect(auth.config.contains(#"user = "AKIA:TOPSECRET""#))
    }

    @Test func basicModePutsPasswordInConfigOnly() {
        let auth = MunkiRepoStore.curlAuth(mode: "basic", basicUser: "bob", basicPassword: "pw!23",
                                           accessKey: "", secretKey: "", region: "")
        #expect(auth.args.isEmpty)
        #expect(auth.config == "user = \"bob:pw!23\"\n")
    }

    @Test func bothModeStacksS3AndBasicHeaderWithoutLeakingToArgs() {
        let auth = MunkiRepoStore.curlAuth(mode: "both", basicUser: "bob", basicPassword: "bpw",
                                           accessKey: "AK", secretKey: "SK", region: "eu")
        let argstr = auth.args.joined(separator: " ")
        #expect(argstr.contains("--aws-sigv4"))
        #expect(!argstr.contains("SK"))
        #expect(!argstr.contains("bpw"))
        #expect(auth.config.contains(#"user = "AK:SK""#))
        #expect(auth.config.contains("Authorization: Basic "))
    }

    @Test func noneModeIsEmpty() {
        let auth = MunkiRepoStore.curlAuth(mode: "none", basicUser: "x", basicPassword: "y",
                                           accessKey: "a", secretKey: "b", region: "c")
        #expect(auth.args.isEmpty)
        #expect(auth.config.isEmpty)
    }

    // MARK: PackageCatalogStore.curlUploadCreds

    @Test func uploadCredsExtractsUserinfoFromURL() {
        let (url, config) = PackageCatalogStore.curlUploadCreds(from: "ftp://bob:s3cr3t@host.example/dir/")
        #expect(!url.contains("s3cr3t"))
        #expect(!url.contains("bob"))
        #expect(url == "ftp://host.example/dir/")
        #expect(config == "user = \"bob:s3cr3t\"\n")
    }

    @Test func uploadCredsWithoutUserinfoIsUnchanged() {
        let (url, config) = PackageCatalogStore.curlUploadCreds(from: "https://nc.example/remote.php/dav/x")
        #expect(url == "https://nc.example/remote.php/dav/x")
        #expect(config.isEmpty)
    }
}
