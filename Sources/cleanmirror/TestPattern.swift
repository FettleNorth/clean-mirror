import CoreVideo

/// A static 1920×1080 test card, computed pixel by pixel (no Core Graphics, so nothing can dither it).
/// Four bands, top to bottom:
///   1. grey ramp 0–255
///   2. slow grey ramp 96–160, where dithering would be easiest to see
///   3. red, green and blue ramps side by side
///   4. flat patches: black, 25 %, 50 %, 75 %, white, and three mid colours
func makeTestPattern(width: Int, height: Int) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
          let pb else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return nil }
    let rowBytes = CVPixelBufferGetBytesPerRow(pb)
    let band = height / 4

    func ramp(_ x: Int, _ x0: Int, _ x1: Int, _ lo: Int, _ hi: Int) -> UInt8 {
        let t = Double(x - x0) / Double(max(1, x1 - x0 - 1))
        return UInt8(clamping: lo + Int((Double(hi - lo) * t).rounded()))
    }

    let patches: [(UInt8, UInt8, UInt8)] = [
        (0, 0, 0), (64, 64, 64), (128, 128, 128), (191, 191, 191), (255, 255, 255),
        (180, 90, 60), (60, 140, 90), (70, 90, 170),
    ]

    for y in 0..<height {
        let row = base + y * rowBytes
        for x in 0..<width {
            var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0
            switch y / band {
            case 0:
                let v = ramp(x, 0, width, 0, 255); r = v; g = v; b = v
            case 1:
                let v = ramp(x, 0, width, 96, 160); r = v; g = v; b = v
            case 2:
                let third = width / 3
                let v = ramp(x % third, 0, third, 0, 255)
                switch x / third { case 0: r = v; case 1: g = v; default: b = v }
            default:
                let p = patches[min(patches.count - 1, x * patches.count / width)]
                r = p.0; g = p.1; b = p.2
            }
            let i = x * 4
            row[i] = b; row[i + 1] = g; row[i + 2] = r; row[i + 3] = 255
        }
    }
    return pb
}
