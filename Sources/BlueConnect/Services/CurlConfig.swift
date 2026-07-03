import Foundation

/// Helpers for handing curl its credentials through a `--config -` file read
/// from **stdin** instead of on the command line. Anything passed as a curl
/// argument (`--user u:p`, or a `user:pass@host` URL) is visible to any local
/// process via `ps -ww` for the life of the request; a config on stdin is not.
enum CurlConfig {
    /// Escape a value for a double-quoted curl config entry. curl recognizes
    /// `\\` and `\"` (plus `\t \n \r \v`) inside double quotes.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// A `user = "u:p"` config line (curl's `--user`).
    static func userLine(user: String, password: String) -> String {
        "user = \"\(escape("\(user):\(password)"))\"\n"
    }

    /// A `header = "…"` config line (curl's `--header`).
    static func headerLine(_ value: String) -> String {
        "header = \"\(escape(value))\"\n"
    }
}
