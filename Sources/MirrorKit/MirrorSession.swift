import Foundation
import CoreGraphics

public struct MirrorConfig {
    public var fps: Int
    public var hidpi: Bool
    public var queuedFrames: Int
    public var useMainDisplay: Bool

    public init(fps: Int = 60, hidpi: Bool = false, queuedFrames: Int = 2, useMainDisplay: Bool = false) {
        self.fps = fps
        self.hidpi = hidpi
        self.queuedFrames = queuedFrames
        self.useMainDisplay = useMainDisplay
    }
}

/// One run of the mirror: the box, the Clean Mirror screen (unless mirroring the main display),
/// and the capture feeding one into the other.
public final class MirrorSession {
    public static let outputWidth = 1920
    public static let outputHeight = 1080

    public let config: MirrorConfig
    public private(set) var deviceName = ""
    public private(set) var displayID: CGDirectDisplayID = 0
    public private(set) var displaySize = (width: 0, height: 0)
    public private(set) var warning: String?
    /// Called (on the capture's thread) if macOS stops the capture by itself.
    public var onCaptureStopped: ((Error) -> Void)?

    private var box: BoxOutput?
    private var screen: VirtualScreen?
    private var capture: ScreenCapture?
    private var started = Date()

    public init(config: MirrorConfig) {
        self.config = config
    }

    public func start() async throws {
        guard screenRecordingAllowed() else { throw MirrorError.needsScreenRecording }
        let box = try BoxOutput(fps: config.fps, queuedFrames: config.queuedFrames)
        do {
            var wanted: CGDirectDisplayID?
            if !config.useMainDisplay {
                let s = try VirtualScreen(width: Self.outputWidth, height: Self.outputHeight,
                                          refreshHz: config.fps, hidpi: config.hidpi)
                screen = s
                wanted = s.displayID
                warning = s.modeWarning
            }
            let cap = ScreenCapture(width: Self.outputWidth, height: Self.outputHeight, fps: config.fps, showsCursor: true)
            cap.onFrame = { [weak box] frame in box?.submit(frame.pixelBuffer) }
            cap.onStop = { [weak self] error in self?.onCaptureStopped?(error) }
            let display = try await cap.start(displayID: wanted)
            try box.start()
            capture = cap
            self.box = box
            deviceName = box.deviceName
            displayID = display.displayID
            displaySize = (display.width, display.height)
            started = Date()
        } catch {
            box.close()
            screen?.remove()
            screen = nil
            if let e = error as? MirrorError { throw e }
            throw MirrorError.capture(error.localizedDescription)
        }
    }

    /// Stops everything: the capture, the box (released for other apps) and the Clean Mirror screen.
    public func stop() async {
        await capture?.stop()
        capture = nil
        stopNow()
    }

    /// Releases the box and removes the screen straight away, without waiting for the capture to wind down.
    /// For use when the program is about to exit anyway.
    public func stopNow() {
        box?.close()
        box = nil
        screen?.remove()
        screen = nil
    }

    public var isRunning: Bool { box != nil }
    public var runningTime: TimeInterval { Date().timeIntervalSince(started) }

    /// New screen frames since the last call, and the box's running totals.
    public func sample() -> (newScreenFrames: Int, box: BoxStats) {
        (capture?.takeCounts().new ?? 0, box?.stats() ?? BoxStats())
    }

    /// The box's running totals, without touching the screen frame counter.
    public func boxStats() -> BoxStats { box?.stats() ?? BoxStats() }

    public var totalScreenFrames: Int { capture?.totalFrames ?? 0 }
}
