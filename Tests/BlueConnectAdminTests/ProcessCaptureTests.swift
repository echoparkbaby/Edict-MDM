import Foundation
import Testing
@testable import BlueConnectAdmin

/// Output larger than the ~64 KB pipe buffer on BOTH streams. Reading only
/// after waitUntilExit() deadlocked here; runCapturing must return.
@Suite("Process.runCapturing")
struct ProcessCaptureTests {
    @Test func drainsLargeStdoutAndStderr() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "head -c 300000 /dev/zero; head -c 200000 /dev/zero >&2"]
        let (out, err) = try p.runCapturing()
        #expect(out.count == 300_000)
        #expect(err.count == 200_000)
        #expect(p.terminationStatus == 0)
    }
}
