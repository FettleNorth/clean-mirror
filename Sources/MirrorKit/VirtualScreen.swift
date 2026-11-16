import Foundation
import CoreGraphics
import VirtualDisplay

/// The "Clean Mirror" screen: a virtual display that exists only while this object does.
public final class VirtualScreen {
    public let displayID: CGDirectDisplayID
    public let width: Int
    public let height: Int
    public let hidpi: Bool
    /// Set if macOS gave the screen a different mode from the one asked for.
    public private(set) var modeWarning: String?

    private let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?

    public static var isAvailable: Bool { vd_available() }

    /// Creates the screen and waits (up to 5 s) for macOS to give it its mode.
    /// `width`×`height` is what it looks like; with `hidpi` it is drawn at twice that.
    public init(width: Int, height: Int, refreshHz: Int, hidpi: Bool) throws {
        guard vd_available() else { throw MirrorError.virtualScreenUnavailable }
        var id: CGDirectDisplayID = 0
        var created: UnsafeMutableRawPointer?
        // Right after a previous Clean Mirror screen is removed, macOS can briefly refuse a new one.
        for _ in 0..<6 {
            created = vd_create("Clean Mirror", Int32(width), Int32(height), Double(refreshHz), hidpi, &id)
            if created != nil && id != 0 { break }
            if let c = created { vd_destroy(c) }
            created = nil
            usleep(500_000)
        }
        guard let created, id != 0 else { throw MirrorError.virtualScreenFailed }
        handle = created
        displayID = id
        self.width = width
        self.height = height
        self.hidpi = hidpi

        let wantedPixels = (width * (hidpi ? 2 : 1), height * (hidpi ? 2 : 1))
        func ready() -> Bool {
            guard let mode = CGDisplayCopyDisplayMode(id) else { return false }
            return mode.width == width && mode.height == height &&
                   mode.pixelWidth == wantedPixels.0 && mode.pixelHeight == wantedPixels.1
        }
        for i in 0..<50 where !ready() {
            if hidpi && i == 15 { _ = vd_use_hidpi_mode(id, Int32(width), Int32(height)) }
            usleep(100_000)
        }
        if !ready(), let mode = CGDisplayCopyDisplayMode(id) {
            modeWarning = "The Clean Mirror screen came up as \(mode.width)×\(mode.height) (\(mode.pixelWidth)×\(mode.pixelHeight) pixels), not as planned."
        }
    }

    /// Removes the screen. Its windows move back to the other screens.
    public func remove() {
        lock.lock(); defer { lock.unlock() }
        if let h = handle {
            vd_destroy(h)
            handle = nil
        }
    }

    deinit { remove() }
}
