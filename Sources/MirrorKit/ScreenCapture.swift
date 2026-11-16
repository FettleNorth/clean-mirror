import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// One new frame from ScreenCaptureKit, with the areas macOS says it redrew.
public struct CapturedFrame {
    public let pixelBuffer: CVPixelBuffer
    public let dirtyRects: [CGRect]
    public let contentRect: CGRect?
    public let scaleFactor: Double?
    public let contentScale: Double?
}

/// Captures one display, scaled to a fixed size, as 8-bit BGRA in sRGB.
/// ScreenCaptureKit only delivers a new frame when something on screen changes;
/// otherwise it reports the frame as idle and the box keeps showing the last one.
public final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    public let width: Int
    public let height: Int
    public let fps: Int
    public let showsCursor: Bool
    public var onFrame: ((CapturedFrame) -> Void)?
    /// Called if macOS stops the capture by itself (for example when the display goes away).
    public var onStop: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "cleanmirror.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var newFrames = 0
    private var idleFrames = 0
    private var totalNewFrames = 0

    public init(width: Int, height: Int, fps: Int, showsCursor: Bool) {
        self.width = width
        self.height = height
        self.fps = fps
        self.showsCursor = showsCursor
    }

    /// New and idle frame counts since the last call.
    public func takeCounts() -> (new: Int, idle: Int) {
        lock.lock(); defer { lock.unlock() }
        let result = (newFrames, idleFrames)
        newFrames = 0
        idleFrames = 0
        return result
    }

    public var totalFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return totalNewFrames
    }

    /// Starts capturing `displayID`, or the main display if nil. A display that was only just created
    /// can take a moment to show up, so this waits up to 5 seconds for it.
    public func start(displayID: CGDirectDisplayID? = nil) async throws -> SCDisplay {
        let wanted = displayID ?? CGMainDisplayID()
        var found: SCDisplay?
        for attempt in 0..<25 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            found = content.displays.first(where: { $0.displayID == wanted })
            if found == nil && displayID == nil { found = content.displays.first }
            if found != nil || attempt == 24 { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let display = found else { throw MirrorError.displayNotFound }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.captureResolution = .best
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.backgroundColor = CGColor.black
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 6
        config.showsCursor = showsCursor

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        return display
    }

    public func stop() async {
        let s = stream
        stream = nil
        try? await s?.stopCapture()
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw) else { return }

        guard status == .complete, let pixelBuffer = sampleBuffer.imageBuffer else {
            lock.lock(); idleFrames += 1; lock.unlock()
            return
        }

        var dirty: [CGRect] = []
        if let rects = info[.dirtyRects] as? [NSDictionary] {
            for dict in rects {
                if let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) { dirty.append(rect) }
            }
        }
        let contentRect = (info[.contentRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        let scaleFactor = (info[.scaleFactor] as? NSNumber)?.doubleValue
        let contentScale = (info[.contentScale] as? NSNumber)?.doubleValue

        lock.lock(); newFrames += 1; totalNewFrames += 1; lock.unlock()

        onFrame?(CapturedFrame(pixelBuffer: pixelBuffer, dirtyRects: dirty, contentRect: contentRect,
                               scaleFactor: scaleFactor, contentScale: contentScale))
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}
