import Foundation
import CoreGraphics
import MirrorKit

setvbuf(stdout, nil, _IOLBF, 0)

let outputWidth = MirrorSession.outputWidth
let outputHeight = MirrorSession.outputHeight

let usage = """
cleanmirror: show a Mac screen on a Blackmagic UltraStudio, bypassing the Mac's own display output.

Usage:
  cleanmirror                     Create a 1920x1080 screen called "Clean Mirror" and send it to the UltraStudio at 1080p60
  cleanmirror --hidpi             Make the Clean Mirror screen Retina: drawn at 3840x2160, halved exactly for the box
  cleanmirror --main              Mirror the main display instead, scaled down to 1920x1080
  cleanmirror --fps 50            Output frame rate: 25, 30, 50 or 60
  cleanmirror --queue 4           Frames waiting in the box, 2-8 (default 2: least delay; more is steadier)
  cleanmirror --selftest [secs]   Check that captured frames are clean (default 30 s, main display, no Blackmagic box needed)
  cleanmirror --selftest 60 --virtual   Same, on a new "Clean Mirror" screen
  cleanmirror --testpattern [secs] Send a static gradient test pattern to the UltraStudio (no screen capture)
  cleanmirror --devices           List Blackmagic devices and the 1080p modes they can output
  cleanmirror --label <name>      Add a name to the self-test's saved files, e.g. --label stillcolor-off
  cleanmirror --verbose           Print extra detail
  cleanmirror --help
"""

enum Mode { case mirror, selftest, testpattern, devices, help }
enum Source { case virtualScreen, mainDisplay }

struct Options {
    var mode = Mode.mirror
    var fps = 60
    var queue = 2
    var seconds = 30.0
    var verbose = false
    var label = ""
    var source: Source?   // nil: virtual screen for the mirror, main display for the self-test
    var hidpi = false
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--selftest":
            options.mode = .selftest
            if let next = args.first, let secs = Double(next) {
                options.seconds = secs
                args.removeFirst()
            }
        case "--fps":
            guard let next = args.first, let fps = Int(next), [25, 30, 50, 60].contains(fps) else {
                fail("--fps needs 25, 30, 50 or 60")
            }
            options.fps = fps
            args.removeFirst()
        case "--queue":
            guard let next = args.first, let q = Int(next), (2...8).contains(q) else {
                fail("--queue needs a number from 2 to 8")
            }
            options.queue = q
            args.removeFirst()
        case "--testpattern":
            options.mode = .testpattern
            options.seconds = 0
            if let next = args.first, let secs = Double(next) {
                options.seconds = secs
                args.removeFirst()
            }
        case "--devices":
            options.mode = .devices
        case "--label":
            guard let next = args.first, !next.hasPrefix("--") else { fail("--label needs a name") }
            options.label = next.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            args.removeFirst()
        case "--main":
            options.source = .mainDisplay
        case "--virtual":
            options.source = .virtualScreen
        case "--hidpi", "--retina":
            options.hidpi = true
        case "--verbose", "-v":
            options.verbose = true
        case "--help", "-h":
            options.mode = .help
        default:
            fail("Unknown option: \(arg)\n\n\(usage)")
        }
    }
    return options
}

func ensureScreenRecordingPermission() {
    if screenRecordingAllowed() { return }
    requestScreenRecording()
    fail("""
    macOS needs Screen Recording permission for the app you ran this from (usually Terminal).
      1. Open System Settings > Privacy & Security > Screen & System Audio Recording.
      2. Turn on the app you ran this from.
      3. Quit and reopen that app, then run this again.
    """)
}

/// Reads the display-dithering flag that Stillcolor sets, so each self-test report records it.
func ditheringFlagState() -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    task.arguments = ["-lw0"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return "unknown" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    let off = text.components(separatedBy: "\"enableDither\" = No").count - 1
    let on = text.components(separatedBy: "\"enableDither\" = Yes").count - 1
    if off == 0 && on == 0 { return "not reported (dithering at default, Stillcolor not active)" }
    if on == 0 { return "dithering OFF on \(off) display pipes (Stillcolor active)" }
    if off == 0 { return "dithering ON on \(on) display pipes" }
    return "mixed: OFF on \(off), ON on \(on) display pipes"
}

func clockString(_ t: TimeInterval) -> String {
    let s = Int(t)
    return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}

// MARK: Self-test

func runSelfTest(_ options: Options) async {
    ensureScreenRecordingPermission()
    let source = options.source ?? .mainDisplay
    let test = SelfTest(width: outputWidth, height: outputHeight, verbose: options.verbose)
    let capture = ScreenCapture(width: outputWidth, height: outputHeight, fps: 60, showsCursor: false)
    capture.onFrame = { test.process($0) }
    var screen: VirtualScreen?

    do {
        if source == .virtualScreen {
            let s = try VirtualScreen(width: outputWidth, height: outputHeight, refreshHz: 60, hidpi: options.hidpi)
            screen = s
            if let warning = s.modeWarning { print("Warning: \(warning)") }
            let display = try await capture.start(displayID: s.displayID)
            let how = options.hidpi ? "Retina, drawn at \(outputWidth * 2)×\(outputHeight * 2) and halved" : "captured without scaling"
            print("Self-test: created the \"Clean Mirror\" screen (display \(display.displayID), \(display.width)×\(display.height), \(how)), for \(Int(options.seconds)) s.")
            print("Drag a window with a video playing onto the Clean Mirror screen now (it's next to your main screen).")
        } else {
            let display = try await capture.start()
            print("Self-test: capturing display \(display.displayID) (\(display.width)×\(display.height) points), scaled to \(outputWidth)×\(outputHeight), for \(Int(options.seconds)) s.")
            print("Keep something moving on screen: scroll a page, drag a window, or play a small video.")
        }
        print("Display dithering flag: \(ditheringFlagState())")
        print("The pointer is hidden for this test.")
    } catch {
        screen?.remove()
        fail("Couldn't start screen capture: \(error.localizedDescription)")
    }

    let start = Date()
    while true {
        let remaining = options.seconds - Date().timeIntervalSince(start)
        if remaining <= 0 { break }
        try? await Task.sleep(nanoseconds: UInt64(min(5, remaining) * 1_000_000_000))
        let counts = capture.takeCounts()
        print(String(format: "  %3.0f s: %ld new frames, %ld idle", Date().timeIntervalSince(start), counts.new, counts.idle))
    }
    await capture.stop()
    screen?.remove()
    let report = test.report
    print(report)

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let stamp = formatter.string(from: Date())
    let base = "selftest-" + stamp + (source == .virtualScreen ? (options.hidpi ? "-virtual-hidpi" : "-virtual") : "")
        + (options.label.isEmpty ? "" : "-" + options.label)
    let header = "Self-test \(stamp)\(options.label.isEmpty ? "" : " (" + options.label + ")"), \(Int(options.seconds)) s, "
        + (source == .virtualScreen ? (options.hidpi ? "Clean Mirror virtual screen, Retina, halved 2:1" : "Clean Mirror virtual screen, no scaling") : "main display, scaled") + "\n"
        + "Display dithering flag: \(ditheringFlagState())\n"
    if (try? (header + report + "\n").write(toFile: base + ".txt", atomically: true, encoding: .utf8)) != nil {
        print("Saved \(FileManager.default.currentDirectoryPath)/\(base).txt")
    }
    if test.strayPixels > 0 {
        let url = URL(fileURLWithPath: base + ".png")
        if test.saveStrayImage(to: url) {
            print("Saved \(url.path): red marks pixels that changed where nothing was redrawn.")
        }
    }
}

// MARK: Devices

func listDevices() {
    guard let result = BoxOutput.listDevices() else {
        fail("The Blackmagic Desktop Video driver isn't installed (or couldn't be loaded).")
    }
    if result.count == 0 {
        print("No Blackmagic devices found. Check the UltraStudio is plugged in and shows up in Desktop Video Setup.")
        return
    }
    print("Blackmagic devices:")
    print(result.text, terminator: "")
}

// MARK: Output loop shared by the mirror and the test pattern

/// Prints stats every 5 seconds until Ctrl-C (or `seconds`, if given), then runs `stop` and exits.
func runOutputLoop(seconds: Double?,
                   sample: @escaping () -> (newScreenFrames: Int?, box: BoxStats),
                   stop: @escaping () -> String) async -> Never {
    let started = Date()
    let stopLock = NSLock()
    var stopped = false
    func stopAndExit() -> Never {
        stopLock.lock()
        if stopped { stopLock.unlock(); while true { sleep(1) } }
        stopped = true
        stopLock.unlock()
        let summary = stop()
        print("")
        print(String(format: "Stopped after %.1f min. ", Date().timeIntervalSince(started) / 60) + summary)
        exit(0)
    }

    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigint.setEventHandler { stopAndExit() }
    sigint.resume()

    var last = BoxStats()
    var lastTime = Date()
    while true {
        var wait = 5.0
        if let seconds { wait = min(wait, seconds - Date().timeIntervalSince(started)) }
        if wait <= 0 { stopAndExit() }
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        let now = Date()
        let dt = now.timeIntervalSince(lastTime)
        let s = sample()
        var line = "  " + clockString(now.timeIntervalSince(started)) + "  "
        if let screenFrames = s.newScreenFrames {
            line += String(format: "screen %5.1f new frames/s | ", Double(screenFrames) / dt)
        }
        line += String(format: "box %5.1f frames/s, late %llu, dropped %llu, queued %u",
                       Double(s.box.scheduled - last.scheduled) / dt, s.box.late - last.late,
                       s.box.dropped - last.dropped, s.box.queued)
        print(line)
        last = s.box
        lastTime = now
    }
}

func boxSummary(_ s: BoxStats) -> String {
    "Frames sent \(s.scheduled), on time \(s.completed), late \(s.late), dropped \(s.dropped)."
}

// MARK: Mirror

func runMirror(_ options: Options) async {
    ensureScreenRecordingPermission()
    let source = options.source ?? .virtualScreen
    let session = MirrorSession(config: MirrorConfig(fps: options.fps, hidpi: options.hidpi,
                                                     queuedFrames: options.queue,
                                                     useMainDisplay: source == .mainDisplay))
    do {
        try await session.start()
    } catch {
        fail("Couldn't start: \(error.localizedDescription)")
    }
    if let warning = session.warning { print("Warning: \(warning)") }

    let delay = Double(options.queue) * 1000 / Double(options.fps)
    if source == .virtualScreen {
        let (w, h) = session.displaySize
        if options.hidpi {
            print("Created a Retina screen called \"Clean Mirror\" (looks like \(w)×\(h), drawn at \(outputWidth * 2)×\(outputHeight * 2)) at \(options.fps) Hz, halved exactly for \(session.deviceName) at 1080p\(options.fps).")
        } else {
            print("Created a \(w)×\(h) screen called \"Clean Mirror\" at \(options.fps) Hz, shown on \(session.deviceName) at 1080p\(options.fps) without scaling.")
        }
        print("Drag windows onto it to see them on the reference monitor. Arrange it in System Settings > Displays.")
        print("When you stop, the screen disappears and its windows move back to your main screen.")
    } else {
        print("Mirroring display \(session.displayID) (\(session.displaySize.width)×\(session.displaySize.height) points) to \(session.deviceName) at 1080p\(options.fps), scaled to fit.")
    }
    print(String(format: "%ld frames queued in the box (about %.0f ms). Press Ctrl-C to stop.", options.queue, delay))

    await runOutputLoop(seconds: nil,
                        sample: { let s = session.sample(); return (s.newScreenFrames, s.box) },
                        stop: {
                            let s = session.sample().box
                            let frames = session.totalScreenFrames
                            session.stopNow()
                            return boxSummary(s) + " Screen frames captured \(frames)."
                        })
}

// MARK: Test pattern

func runTestPattern(_ options: Options) async {
    let box: BoxOutput
    do {
        box = try BoxOutput(fps: options.fps, queuedFrames: options.queue)
    } catch {
        fail("Couldn't open the UltraStudio: \(error.localizedDescription)")
    }
    guard let pattern = makeTestPattern(width: outputWidth, height: outputHeight) else {
        box.close()
        fail("Couldn't build the test pattern.")
    }
    box.submit(pattern)
    do { try box.start() } catch {
        box.close()
        fail("Couldn't start the UltraStudio: \(error.localizedDescription)")
    }
    print("Showing a static test pattern on \(box.deviceName) at 1080p\(options.fps), \(options.queue) frames queued. Nothing on it should ever change.")
    print(options.seconds > 0 ? "Running for \(Int(options.seconds)) s." : "Press Ctrl-C to stop.")
    await runOutputLoop(seconds: options.seconds > 0 ? options.seconds : nil,
                        sample: { (nil, box.stats()) },
                        stop: {
                            let s = box.stats()
                            box.close()
                            return boxSummary(s)
                        })
}

let options = parseOptions()
switch options.mode {
case .help:
    print(usage)
case .devices:
    listDevices()
case .selftest:
    await runSelfTest(options)
case .testpattern:
    await runTestPattern(options)
case .mirror:
    await runMirror(options)
}
