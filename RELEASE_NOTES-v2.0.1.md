## Edict MDM 2.0.1

A small fix release. Requires **macOS 15 or later**.

### Fixed

- **Plain `http://` servers now work for everyone.** 2.0.0 only allowed unencrypted connections to a fixed list of addresses built into the app, so an MDM or MunkiReport server reached over `http://` (for example on a Tailscale or LAN address) could not connect. Edict now allows plain HTTP to the servers you enter in Settings or on the sign-in screen, and to local addresses. Plain HTTP to anything else is refused with a message that says why.
- The **GUI Helper** links in Quick Actions now download `BlueConnectHelper.pkg` from the Edict-MDM releases instead of the BlueConnect Admin repository.

### Good to know

- To make the first fix possible, the app no longer relies on macOS's built-in App Transport Security rules; Edict applies its own plain-HTTP rule instead. HTTPS connections still validate certificates as before.
- Use `https://` for any server reached over the internet.

### Full changelog

[CHANGELOG.md](https://github.com/echoparkbaby/Edict-MDM/blob/main/CHANGELOG.md)
