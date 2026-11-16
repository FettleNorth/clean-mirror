import Foundation
import MirrorKit
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Compares each captured frame with the one before it. Any pixel that changed
/// outside the areas macOS says it redrew is a "stray" change: the kind of
/// frame-to-frame noise temporal dithering would cause.
struct StrayEvent {
    let time: Double          // seconds since the test started
    let pixels: Int
    let oneLevel: Int
    let largest: Int
    let box: (minX: Int, minY: Int, maxX: Int, maxY: Int)
    let redrawnAreas: Int
}

final class SelfTest {
    let width: Int
    let height: Int
    /// Pixels of slack around each redrawn area, because scaling down spreads
    /// a change slightly beyond its edges.
    let margin: Int
    let verbose: Bool

    private let lock = NSLock()
    private var previous: [UInt8]
    private var hasPrevious = false
    private var mask: [UInt8]
    private var heat: [UInt16]
    private var debugFramesLeft = 8

    private(set) var frames = 0
    private(set) var comparedFrames = 0
    private(set) var framesWithoutDirtyInfo = 0
    private(set) var framesWithStrayChanges = 0
    private(set) var strayPixels = 0
    private(set) var redrawnPixelsChanged = 0
    private(set) var maxStrayDelta = 0
    /// Stray changes by size: 1 level, 2 levels, 3 levels, 4 or more.
    private(set) var strayBySize = [0, 0, 0, 0]
    private(set) var events: [StrayEvent] = []
    private let started = Date()

    init(width: Int, height: Int, margin: Int = 4, verbose: Bool = false) {
        self.width = width
        self.height = height
        self.margin = margin
        self.verbose = verbose
        previous = [UInt8](repeating: 0, count: width * height * 4)
        mask = [UInt8](repeating: 0, count: width * height)
        heat = [UInt16](repeating: 0, count: width * height)
    }

    func process(_ frame: CapturedFrame) {
        let pb = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferGetWidth(pb) == width, CVPixelBufferGetHeight(pb) == height,
              let raw = CVPixelBufferGetBaseAddress(pb) else { return }
        let base = UnsafePointer(raw.assumingMemoryBound(to: UInt8.self))
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)

        lock.lock(); defer { lock.unlock() }
        frames += 1
        if hasPrevious {
            if frame.dirtyRects.isEmpty {
                framesWithoutDirtyInfo += 1
            } else {
                compare(base: base, rowBytes: rowBytes, frame: frame)
            }
        }
        let lineBytes = width * 4
        previous.withUnsafeMutableBufferPointer { p in
            for y in 0..<height {
                memcpy(p.baseAddress! + y * lineBytes, base + y * rowBytes, lineBytes)
            }
        }
        hasPrevious = true
    }

    private func compare(base: UnsafePointer<UInt8>, rowBytes: Int, frame: CapturedFrame) {
        let w = width, h = height, m = margin

        mask.withUnsafeMutableBufferPointer { mk in
            memset(mk.baseAddress!, 0, mk.count)
            for r in frame.dirtyRects {
                let x0 = max(0, Int(r.minX.rounded(.down)) - m), x1 = min(w, Int(r.maxX.rounded(.up)) + m)
                let y0 = max(0, Int(r.minY.rounded(.down)) - m), y1 = min(h, Int(r.maxY.rounded(.up)) + m)
                guard x0 < x1, y0 < y1 else { continue }
                for y in y0..<y1 { memset(mk.baseAddress! + y * w + x0, 1, x1 - x0) }
            }
        }

        var stray = 0, inside = 0, maxDelta = 0
        var bySize = [0, 0, 0, 0]
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        var sMinX = Int.max, sMinY = Int.max, sMaxX = -1, sMaxY = -1

        previous.withUnsafeBufferPointer { pv in
            mask.withUnsafeBufferPointer { mk in
                heat.withUnsafeMutableBufferPointer { ht in
                    for y in 0..<h {
                        let cur = base + y * rowBytes
                        let old = pv.baseAddress! + y * w * 4
                        if memcmp(cur, old, w * 4) == 0 { continue }
                        for x in 0..<w {
                            let i = x * 4
                            let db = abs(Int(cur[i]) - Int(old[i]))
                            let dg = abs(Int(cur[i + 1]) - Int(old[i + 1]))
                            let dr = abs(Int(cur[i + 2]) - Int(old[i + 2]))
                            let d = max(db, dg, dr)
                            if d == 0 { continue }
                            minX = min(minX, x); maxX = max(maxX, x)
                            minY = min(minY, y); maxY = max(maxY, y)
                            let p = y * w + x
                            if mk[p] != 0 { inside += 1; continue }
                            stray += 1
                            sMinX = min(sMinX, x); sMaxX = max(sMaxX, x)
                            sMinY = min(sMinY, y); sMaxY = max(sMaxY, y)
                            bySize[min(d, 4) - 1] += 1
                            maxDelta = max(maxDelta, d)
                            if ht[p] < UInt16.max { ht[p] += 1 }
                        }
                    }
                }
            }
        }

        comparedFrames += 1
        redrawnPixelsChanged += inside
        strayPixels += stray
        if stray > 0 {
            framesWithStrayChanges += 1
            let event = StrayEvent(time: Date().timeIntervalSince(started), pixels: stray, oneLevel: bySize[0],
                                   largest: maxDelta, box: (sMinX, sMinY, sMaxX, sMaxY),
                                   redrawnAreas: frame.dirtyRects.count)
            events.append(event)
            print("  " + SelfTest.describe(event))
        }
        maxStrayDelta = max(maxStrayDelta, maxDelta)
        for i in 0..<4 { strayBySize[i] += bySize[i] }

        if verbose && debugFramesLeft > 0 {
            debugFramesLeft -= 1
            let rects = frame.dirtyRects.map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height)))" }.joined(separator: " ")
            let box = maxX >= 0 ? "(\(minX),\(minY))–(\(maxX),\(maxY))" : "none"
            print("  [debug] redrawn: \(rects)")
            print("  [debug] changed pixels span \(box); \(inside) inside redrawn areas, \(stray) stray; contentRect \(frame.contentRect.map { "\($0)" } ?? "-") scale \(frame.scaleFactor ?? 0) contentScale \(frame.contentScale ?? 0)")
        }
    }

    static func describe(_ e: StrayEvent) -> String {
        let pct = e.pixels > 0 ? 100 * e.oneLevel / e.pixels : 0
        let share = String(format: "%.1f", 100 * Double(e.pixels) / Double(1920 * 1080))
        return String(format: "stray event at %5.1f s: ", e.time)
            + "\(e.pixels) pixels (\(share) % of the frame, \(pct) % 1-level, largest \(e.largest)) "
            + "within (\(e.box.minX),\(e.box.minY))–(\(e.box.maxX),\(e.box.maxY)); macOS reported \(e.redrawnAreas) redrawn areas"
    }

    var report: String {
        lock.lock(); defer { lock.unlock() }
        var lines: [String] = []
        lines.append("")
        lines.append("Self-test result")
        lines.append("  New frames captured:            \(frames)")
        lines.append("  Frames compared:                \(comparedFrames)")
        if framesWithoutDirtyInfo > 0 {
            lines.append("  Frames skipped (no redraw info): \(framesWithoutDirtyInfo)")
        }
        lines.append("  Pixels changed in redrawn areas: \(redrawnPixelsChanged)")
        lines.append("  Stray pixel changes:            \(strayPixels) in \(framesWithStrayChanges) frames")
        if strayPixels > 0 {
            lines.append("    by size: 1 level \(strayBySize[0]), 2 levels \(strayBySize[1]), 3 levels \(strayBySize[2]), 4+ levels \(strayBySize[3]); largest \(maxStrayDelta)")
        }
        if !events.isEmpty {
            lines.append("")
            lines.append("Stray events:")
            for e in events.prefix(50) { lines.append("  " + SelfTest.describe(e)) }
            if events.count > 50 { lines.append("  ... and \(events.count - 50) more") }
        }
        lines.append("")
        if comparedFrames < 5 {
            lines.append("NOT ENOUGH DATA: too few frames changed to test. Keep something moving on screen and run it again.")
        } else if strayPixels == 0 {
            lines.append("CLEAN: across \(comparedFrames) frames, no pixel changed anywhere macOS didn't redraw.")
        } else {
            let share = 100 * Double(framesWithStrayChanges) / Double(comparedFrames)
            lines.append(String(format: "CHANGES FOUND in %ld of %ld frames (%.2f %%).", framesWithStrayChanges, comparedFrames, share))
            if share < 5 {
                lines.append("A handful of frames points to one-off events, not dithering, which would show in most frames.")
                lines.append("Switching apps or dragging windows causes these: translucent menu bar, Dock and window")
                lines.append("backgrounds shift by about 1 level, and macOS doesn't count that as a redraw.")
                lines.append("Check the event times above against what you were doing.")
            } else {
                lines.append("Stray changes in this many frames would fit dithering or an unreported animation.")
                lines.append("Look at the saved image to see where they are.")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Writes the last captured frame, dimmed, with stray pixels marked in red.
    func saveStrayImage(to url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for p in 0..<(width * height) {
            let i = p * 4
            if heat[p] > 0 {
                out[i] = 0; out[i + 1] = 0; out[i + 2] = 255
            } else {
                out[i] = previous[i] / 3; out[i + 1] = previous[i + 1] / 3; out[i + 2] = previous[i + 2] / 3
            }
            out[i + 3] = 255
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let image: CGImage? = out.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: space, bitmapInfo: info)?.makeImage()
        }
        guard let image,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
