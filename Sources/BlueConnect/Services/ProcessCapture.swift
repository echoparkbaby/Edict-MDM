import Foundation

extension Process {
    /// Runs to completion, draining stdout and stderr concurrently. Reading a
    /// pipe only after `waitUntilExit()` deadlocks once the child writes more
    /// than the ~64 KB pipe buffer (child blocks on write, we block on exit).
    /// Synchronous — call off the main actor.
    func runCapturing() throws -> (out: Data, err: Data) {
        let outPipe = Pipe(), errPipe = Pipe()
        standardOutput = outPipe
        standardError = errPipe
        try run()
        var err = Data()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            err = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        waitUntilExit()
        return (out, err)
    }
}
