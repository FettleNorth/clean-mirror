import Foundation
import CoreVideo
import DeckLinkShim

public struct BoxStats {
    public var scheduled: UInt64 = 0
    public var completed: UInt64 = 0
    public var late: UInt64 = 0
    public var dropped: UInt64 = 0
    public var queued: UInt32 = 0
    public init() {}
}

/// The UltraStudio's output: 1080p at a fixed frame rate on the box's own clock, showing the newest
/// frame handed to `submit` on every tick.
public final class BoxOutput {
    public let deviceName: String
    public let fps: Int
    public let queuedFrames: Int

    private let lock = NSLock()
    private var output: OpaquePointer?

    /// Opens the first Blackmagic device that can output 1080p at `fps`.
    /// `queuedFrames` (2–8) is how many frames wait in the box: fewer means less delay, more is steadier.
    public init(fps: Int, queuedFrames: Int) throws {
        var err = [CChar](repeating: 0, count: 512)
        var name = [CChar](repeating: 0, count: 256)
        guard let o = dl_output_open(Int32(fps), Int32(queuedFrames), &err, Int32(err.count), &name, Int32(name.count)) else {
            throw MirrorError.box(String(cString: err))
        }
        output = o
        deviceName = String(cString: name)
        self.fps = fps
        self.queuedFrames = queuedFrames
    }

    /// Starts steady playback. Until the first `submit`, the box shows black.
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard let o = output else { return }
        var err = [CChar](repeating: 0, count: 512)
        guard dl_output_start(o, &err, Int32(err.count)) else { throw MirrorError.box(String(cString: err)) }
    }

    /// Hands over the newest frame (1920×1080 BGRA). Safe to call from any thread.
    public func submit(_ pixelBuffer: CVPixelBuffer) {
        lock.lock(); defer { lock.unlock() }
        if let o = output { dl_output_submit(o, pixelBuffer) }
    }

    public func stats() -> BoxStats {
        lock.lock(); defer { lock.unlock() }
        var s = DLOutputStats()
        if let o = output { dl_output_get_stats(o, &s) }
        var result = BoxStats()
        result.scheduled = s.scheduled
        result.completed = s.completed
        result.late = s.late
        result.dropped = s.dropped
        result.queued = s.buffered
        return result
    }

    /// Stops playback and releases the box, so other apps can use it.
    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let o = output {
            dl_output_stop_and_close(o)
            output = nil
        }
    }

    deinit { close() }

    /// One line per Blackmagic device with the 1080p modes it can output, or nil if the driver is missing.
    public static func listDevices() -> (count: Int, text: String)? {
        var buf = [CChar](repeating: 0, count: 4096)
        let count = dl_list_devices(&buf, Int32(buf.count))
        if count < 0 { return nil }
        return (Int(count), String(cString: buf))
    }
}
