// AF Flow P0 probe: can a Core Audio process tap capture system audio from
// inside AF Flow's App Sandbox?
//
// This exists because published reports say tap behaviour under App Sandbox is
// "fragile" and at least one project disabled the sandbox to make it work. That
// is a claim about someone else's build, not a measurement of Andrew's, and
// turning off an app's sandbox on the strength of a blog post is exactly the
// kind of thing this project sends back to him with evidence attached.
//
// So: the same binary is built twice, once with AF Flow's real sandbox
// entitlements and once without, and the only difference in the result is
// attributable to the sandbox.
//
// It never touches any screen-capture API. Process taps are a separate,
// audio-only TCC category (NSAudioCaptureUsageDescription) and cannot see the
// screen.

import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Reporting

enum Step: String {
    case tapCreate = "create process tap"
    case tapUID = "read tap UID"
    case outputDevice = "find default output device"
    case aggregateCreate = "create aggregate device"
    case ioProc = "install IO proc"
    case ioStart = "start audio IO"
    case capture = "receive audio"
}

// The report goes to a FILE as well as stdout, because the only way to get an
// honest TCC answer is to launch through LaunchServices (`open`), and that
// detaches stdout. Running the binary straight from a shell makes the terminal
// the responsible process, so the permission is attributed to the terminal and
// no prompt for this app ever appears. That is what made the first run look
// like a silent denial.
let reportURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("afflow-tap-probe-report.txt")
var report: [String] = []

func emit(_ line: String) {
    print(line)
    report.append(line)
}

func flushReport() {
    try? report.joined(separator: "\n").appending("\n")
        .write(to: reportURL, atomically: true, encoding: .utf8)
}

func fail(_ step: Step, _ detail: String) -> Never {
    emit("FAIL   \(step.rawValue): \(detail)")
    emit("")
    emit("VERDICT: BLOCKED at \(step.rawValue)")
    flushReport()
    exit(1)
}

func ok(_ step: Step, _ detail: String = "") {
    emit("ok     \(step.rawValue)\(detail.isEmpty ? "" : ": \(detail)")")
}

func osStatusText(_ status: OSStatus) -> String {
    // Core Audio four-char codes are far more useful than the decimal value.
    let value = UInt32(bitPattern: status)
    let chars = [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]
    let printable = chars.allSatisfy { $0 >= 32 && $0 < 127 }
    let code = printable ? "'\(String(bytes: chars, encoding: .ascii) ?? "")'" : "\(status)"
    return "\(code) (\(status))"
}

let sandboxState = ProcessInfo.processInfo.environment["AF_FLOW_PROBE_LABEL"] ?? "unlabelled"
emit("AF Flow audio tap probe — \(sandboxState)")
emit("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
emit("report: \(reportURL.path)")
emit("")

// MARK: - 1. Create the process tap

guard #available(macOS 14.4, *) else {
    fail(.tapCreate, "macOS 14.4 or later is required for Core Audio process taps")
}

let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
tapDescription.uuid = UUID()
tapDescription.name = "AF Flow probe tap"
tapDescription.isPrivate = true
tapDescription.muteBehavior = .unmuted

var tapID = AudioObjectID(kAudioObjectUnknown)
let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)

if tapStatus != noErr || tapID == kAudioObjectUnknown {
    fail(.tapCreate, "AudioHardwareCreateProcessTap returned \(osStatusText(tapStatus))")
}
ok(.tapCreate, "tap object id \(tapID)")

defer {
    if tapID != kAudioObjectUnknown {
        AudioHardwareDestroyProcessTap(tapID)
    }
}

// MARK: - 2. Read the tap's UID, needed to reference it from an aggregate

func stringProperty(
    of object: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString? = nil
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
    }
    guard status == noErr else { return nil }
    return value as String?
}

guard let tapUID = stringProperty(of: tapID, selector: kAudioTapPropertyUID) else {
    fail(.tapUID, "kAudioTapPropertyUID unreadable")
}
ok(.tapUID, tapUID)

// MARK: - 3. Default output device, used as the aggregate's clock source

var defaultOutputAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var outputDeviceID = AudioObjectID(kAudioObjectUnknown)
var outputDeviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
let outputStatus = AudioObjectGetPropertyData(
    AudioObjectID(kAudioObjectSystemObject),
    &defaultOutputAddress,
    0,
    nil,
    &outputDeviceSize,
    &outputDeviceID
)

if outputStatus != noErr || outputDeviceID == kAudioObjectUnknown {
    fail(.outputDevice, "default output device unavailable: \(osStatusText(outputStatus))")
}

guard let outputUID = stringProperty(of: outputDeviceID, selector: kAudioDevicePropertyDeviceUID) else {
    fail(.outputDevice, "output device UID unreadable")
}
let outputName = stringProperty(of: outputDeviceID, selector: kAudioObjectPropertyName) ?? "unknown"
ok(.outputDevice, "\(outputName)")

// MARK: - 4. Aggregate device wrapping the tap

let aggregateUID = "com.frolikov.afflow.probe.aggregate.\(UUID().uuidString)"
let aggregateDescription: [String: Any] = [
    kAudioAggregateDeviceNameKey: "AF Flow probe aggregate",
    kAudioAggregateDeviceUIDKey: aggregateUID,
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [
        [kAudioSubDeviceUIDKey: outputUID]
    ],
    kAudioAggregateDeviceTapListKey: [
        [
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: tapUID,
        ]
    ],
]

var aggregateID = AudioObjectID(kAudioObjectUnknown)
let aggregateStatus = AudioHardwareCreateAggregateDevice(
    aggregateDescription as CFDictionary,
    &aggregateID
)

if aggregateStatus != noErr || aggregateID == kAudioObjectUnknown {
    fail(.aggregateCreate, "AudioHardwareCreateAggregateDevice returned \(osStatusText(aggregateStatus))")
}
ok(.aggregateCreate, "aggregate object id \(aggregateID)")

defer {
    if aggregateID != kAudioObjectUnknown {
        AudioHardwareDestroyAggregateDevice(aggregateID)
    }
}

// MARK: - 5 and 6. Pull audio through it

final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: UInt64 = 0
    private var peak: Float = 0
    private var callbacks: UInt64 = 0

    func record(frameCount: UInt64, peakLevel: Float) {
        lock.lock()
        frames += frameCount
        callbacks += 1
        if peakLevel > peak { peak = peakLevel }
        lock.unlock()
    }

    var snapshot: (frames: UInt64, peak: Float, callbacks: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (frames, peak, callbacks)
    }
}

let capture = Capture()

var ioProcID: AudioDeviceIOProcID?
let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
    &ioProcID,
    aggregateID,
    nil
) { _, inputData, _, _, _ in
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    var frames: UInt64 = 0
    var peak: Float = 0

    for buffer in buffers {
        guard let raw = buffer.mData, buffer.mDataByteSize > 0 else { continue }
        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard sampleCount > 0 else { continue }
        let samples = raw.bindMemory(to: Float.self, capacity: sampleCount)
        for index in 0..<sampleCount {
            let magnitude = abs(samples[index])
            if magnitude > peak { peak = magnitude }
        }
        let channels = max(UInt32(1), buffer.mNumberChannels)
        frames += UInt64(UInt32(sampleCount) / channels)
    }

    capture.record(frameCount: frames, peakLevel: peak)
}

if ioStatus != noErr || ioProcID == nil {
    fail(.ioProc, "AudioDeviceCreateIOProcIDWithBlock returned \(osStatusText(ioStatus))")
}
ok(.ioProc)

let startStatus = AudioDeviceStart(aggregateID, ioProcID)
if startStatus != noErr {
    fail(.ioStart, "AudioDeviceStart returned \(osStatusText(startStatus))")
}
ok(.ioStart)

// The probe plays its OWN audio, so silence is never ambiguous.
//
// An earlier version just captured whatever happened to be playing and called
// zero callbacks "BLOCKED". That cannot tell a blocked tap from a quiet Mac,
// and it produced a confident false negative: a run with nothing playing
// reported BLOCKED while the sandbox was in fact working perfectly. A check
// that cannot distinguish "denied" from "nothing to hear" is the same defect
// this project keeps paying for.
let tone = Process()
tone.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
tone.arguments = ["/System/Library/Sounds/Submarine.aiff"]
var tonePlayed = false
do {
    try tone.run()
    tonePlayed = true
} catch {
    emit("warn   could not play a test tone: \(error.localizedDescription)")
}

let captureSeconds = 4.0
emit("")
emit("Capturing system audio for \(Int(captureSeconds)) seconds\(tonePlayed ? " while playing a known tone" : "")...")

// Keep the tone going for most of the window so a single short sound cannot
// fall entirely outside it.
let toneDeadline = Date().addingTimeInterval(captureSeconds - 0.5)
DispatchQueue.global().async {
    while Date() < toneDeadline {
        let repeatTone = Process()
        repeatTone.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        repeatTone.arguments = ["/System/Library/Sounds/Submarine.aiff"]
        try? repeatTone.run()
        repeatTone.waitUntilExit()
    }
}

Thread.sleep(forTimeInterval: captureSeconds)

AudioDeviceStop(aggregateID, ioProcID)
if let ioProcID {
    AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
}

let result = capture.snapshot
emit("")
emit("callbacks: \(result.callbacks)")
emit("frames:    \(result.frames)")
emit("peak:      \(String(format: "%.5f", result.peak))")
emit("")

// A known tone was played throughout the window, so the three outcomes are now
// distinguishable rather than conflated.
if result.callbacks == 0 || result.frames == 0 {
    fail(.capture, "the IO proc never fired, with a tone playing")
}

ok(.capture, "\(result.frames) frames across \(result.callbacks) callbacks")
emit("")

if result.peak < 0.0001 {
    // Frames arrived but every sample is zero. That is what a denied audio
    // capture looks like: the system hands over correctly shaped silence rather
    // than an error. It is also what you get when the process was launched from
    // a terminal, because TCC then attributes the request to the terminal
    // instead of to this app. Launch with `open -a` before believing this.
    emit("VERDICT: SILENCED — frames arrived but all samples are zero.")
    emit("         Either audio capture is denied for this app, or it was")
    emit("         launched from a shell so TCC attributed the request to the")
    emit("         terminal. Relaunch with 'open -a' before concluding anything.")
    exit(2)
}

emit("VERDICT: WORKS (captured real audio, peak \(String(format: "%.4f", result.peak)))")

flushReport()
