import Foundation

/// The smoke test's host: a tiny executable that runs INSIDE a copy of
/// AF Flow.app so `launchd` can find the embedded service, and proves the one
/// thing the whole Phase 4 design rests on.
///
/// TWO CLAIMS, and the first is the control. This process is sandboxed with no
/// `network.client`, so its OWN fetch must fail in the kernel. The service,
/// carrying that entitlement, must then fetch the same URL and write the bytes
/// into a descriptor this process opened. A run where both succeed proves
/// nothing: it means the sandbox was not applied and the second result is
/// meaningless.
let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: SmokeClient <url>\n".utf8))
    exit(2)
}
let urlString = arguments[1]

func say(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

// THE DESTINATION IS CHOSEN IN HERE, not passed in, because this process is
// sandboxed and can only open a file inside its own container. That is the
// whole point: the service writes into a descriptor for a file it could never
// have opened itself. The caller learns the path from the line below.
let destination = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("xpc-smoke-\(getpid()).bin")
say("destination \(destination.path)")

// --- The control: this process must be denied by the kernel.
var controlResult = "no result"
let controlDone = DispatchSemaphore(value: 0)
URLSession(configuration: .ephemeral).dataTask(with: URL(string: urlString)!) { data, _, error in
    if let error = error as NSError? {
        controlResult = "denied: \(error.domain) \(error.code)"
    } else {
        controlResult = "SUCCEEDED with \(data?.count ?? 0) bytes"
    }
    controlDone.signal()
}.resume()
_ = controlDone.wait(timeout: .now() + 20)
say("control \(controlResult)")

// --- The experiment: the service writes into a descriptor we opened.
FileManager.default.createFile(atPath: destination.path, contents: nil)
guard let handle = try? FileHandle(forWritingTo: destination) else {
    say("service could not open the destination")
    exit(3)
}

final class Progress: NSObject, ModelDownloadProgressProtocol {
    var last: Int64 = 0
    var reports = 0
    func wrote(bytes: Int64, of url: String) { last = bytes; reports += 1 }
}
let progress = Progress()
let connection = NSXPCConnection(serviceName: modelDownloadServiceName)
connection.remoteObjectInterface = NSXPCInterface(with: ModelDownloadServiceProtocol.self)
connection.exportedInterface = NSXPCInterface(with: ModelDownloadProgressProtocol.self)
connection.exportedObject = progress
let finished = DispatchSemaphore(value: 0)
connection.invalidationHandler = { say("service connection invalidated"); finished.signal() }
connection.resume()

let proxy = connection.remoteObjectProxyWithErrorHandler { error in
    say("service unreachable: \(error.localizedDescription)")
    finished.signal()
} as? ModelDownloadServiceProtocol

proxy?.fetch(urlString, into: handle, resumingFrom: 0) { written, error in
    if let error {
        say("service error \(error)")
    } else {
        say("service wrote \(written)")
    }
    finished.signal()
}
if finished.wait(timeout: .now() + 60) == .timedOut {
    say("service timed out")
}
try? handle.close()
say("progress reports \(progress.reports)")
exit(0)
