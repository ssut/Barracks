import AppKit
import Foundation

public struct IconPalette: Sendable, Equatable {
    public var background: SIMD3<Double>
    public var glyph: SIMD3<Double>?
}

public enum IconRecolor {
    static let analysisSize = 256
    static let glyphSeparation = 0.3
    static let minimumGlyphShare = 0.01
    static let coverageSnap = 0.85
    static let offLineStart = 0.12
    static let offLineEnd = 0.25
    static let singleColorStart = 0.1
    static let singleColorEnd = 0.3
    static let bandInner = 0.12
    static let bandOuter = 0.16
    static let minimumContrast = 0.25
    static let lightGlyph = 0.97
    static let darkGlyph = 0.12

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var sources: [String: NSImage] = [:]
    nonisolated(unsafe) private static var palettes: [String: IconPalette] = [:]

    public static func sourceIcon(appURL: URL) -> NSImage {
        let key = appURL.standardizedPath
        cacheLock.lock()
        if let cached = sources[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let image = NSWorkspace.shared.icon(forFile: appURL.path)
        cacheLock.lock()
        sources[key] = image
        cacheLock.unlock()
        return image
    }

    public static func invalidate() {
        cacheLock.lock()
        sources.removeAll()
        palettes.removeAll()
        cacheLock.unlock()
        Log.debug("icon.recolor_cache_cleared")
    }

    public static func render(_ image: NSImage, size: Int) -> CGImage? {
        guard let context = IconComposer.makeContext(size: size) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    public static func palette(appURL: URL) -> IconPalette? {
        let key = appURL.standardizedPath
        cacheLock.lock()
        if let cached = palettes[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        guard let image = render(sourceIcon(appURL: appURL), size: analysisSize), let found = analyze(image) else {
            Log.warning("icon.palette_missing", ["app": appURL.lastPathComponent])
            return nil
        }
        cacheLock.lock()
        palettes[key] = found
        cacheLock.unlock()
        Log.info("icon.palette", [
            "app": appURL.lastPathComponent,
            "background": hex(found.background),
            "glyph": found.glyph.map(hex) ?? "none",
        ])
        return found
    }

    public static func analyze(_ image: CGImage) -> IconPalette? {
        guard let pixels = Pixels(image), let background = borderColor(pixels) else { return nil }
        var sums: [Int: SIMD3<Double>] = [:]
        var counts: [Int: Int] = [:]
        var opaque = 0
        for index in 0..<(pixels.width * pixels.height) {
            let offset = index * 4
            guard pixels.data[offset + 3] >= 250 else { continue }
            opaque += 1
            let color = pixels.color(at: offset)
            guard distance(color, background) > glyphSeparation else { continue }
            let bucket = Int(pixels.data[offset] >> 3) << 10 | Int(pixels.data[offset + 1] >> 3) << 5 | Int(pixels.data[offset + 2] >> 3)
            sums[bucket, default: .zero] += color
            counts[bucket, default: 0] += 1
        }
        guard opaque > 0 else { return nil }
        let glyph = counts
            .max(by: { $0.value < $1.value })
            .flatMap { entry -> SIMD3<Double>? in
                guard Double(entry.value) / Double(opaque) >= minimumGlyphShare else { return nil }
                return sums[entry.key]! / Double(entry.value)
            }
        return IconPalette(background: background, glyph: glyph)
    }

    static func borderColor(_ pixels: Pixels) -> SIMD3<Double>? {
        let size = min(pixels.width, pixels.height)
        let inner = Int(Double(size) * bandInner)
        let outer = Int(Double(size) * bandOuter)
        guard outer > inner else { return nil }
        var reds: [Double] = []
        var greens: [Double] = []
        var blues: [Double] = []
        let span = (size / 4)..<(size - size / 4)
        func sample(_ x: Int, _ y: Int) {
            let offset = (y * pixels.width + x) * 4
            guard pixels.data[offset + 3] >= 250 else { return }
            let color = pixels.color(at: offset)
            reds.append(color.x)
            greens.append(color.y)
            blues.append(color.z)
        }
        for depth in inner..<outer {
            for along in span {
                sample(along, depth)
                sample(along, size - 1 - depth)
                sample(depth, along)
                sample(size - 1 - depth, along)
            }
        }
        guard reds.count >= span.count else { return nil }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        return SIMD3(median(reds), median(greens), median(blues))
    }

    public static func recolor(_ image: CGImage, palette: IconPalette, tint: RGBColor) -> CGImage? {
        guard var pixels = Pixels(image) else { return nil }
        let target = SIMD3(tint.red, tint.green, tint.blue)
        let shift = target - palette.background
        let axis = palette.glyph.map { palette.background - $0 }
        let axisLength = axis.map { simdDot($0, $0) } ?? 0
        let glyphShift = palette.glyph.flatMap { glyph in glyphReplacement(palette: palette, target: target).map { $0 - glyph } }
        for index in 0..<(pixels.width * pixels.height) {
            let offset = index * 4
            let alpha = Double(pixels.data[offset + 3]) / 255
            guard alpha > 0 else { continue }
            let color = pixels.color(at: offset)
            var result = color
            if let glyph = palette.glyph, let axis, axisLength > 0 {
                let coverage = min(max(simdDot(color - glyph, axis) / axisLength, 0), 1)
                let residual = color - (glyph + axis * coverage)
                let nearLine = 1 - smoothstep(offLineStart, offLineEnd, (simdDot(residual, residual)).squareRoot())
                guard nearLine > 0 else { continue }
                let backgroundWeight = min(coverage / coverageSnap, 1) * nearLine
                let chroma = residual - SIMD3(repeating: luminance(residual))
                result += (shift - chroma) * backgroundWeight
                if let glyphShift { result += glyphShift * (1 - coverage) * nearLine }
            } else {
                let weight = 1 - smoothstep(singleColorStart, singleColorEnd, distance(color, palette.background))
                guard weight > 0 else { continue }
                result += shift * weight
            }
            pixels.setColor(simdClamp(result), alpha: alpha, at: offset)
        }
        return pixels.makeImage()
    }

    public static func glyphReplacement(palette: IconPalette, target: SIMD3<Double>) -> SIMD3<Double>? {
        guard let glyph = palette.glyph else { return nil }
        let targetLuminance = luminance(target)
        guard abs(targetLuminance - luminance(glyph)) < minimumContrast else { return nil }
        return targetLuminance < 0.5 ? SIMD3(repeating: lightGlyph) : SIMD3(repeating: darkGlyph)
    }

    static func luminance(_ color: SIMD3<Double>) -> Double {
        0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z
    }

    public static func profileIcon(appURL: URL, tint: ProfileTint, size: Int) -> CGImage? {
        guard let palette = palette(appURL: appURL), let base = render(sourceIcon(appURL: appURL), size: size) else { return nil }
        let target = SIMD3(tint.rgb.red, tint.rgb.green, tint.rgb.blue)
        if size >= 512, glyphReplacement(palette: palette, target: target) != nil {
            Log.info("icon.glyph_contrast_swap", ["app": appURL.lastPathComponent, "tint": tint.cacheKey])
        }
        return recolor(base, palette: palette, tint: tint.rgb)
    }

    public static func officialIcon(appURL: URL, size: Int) -> CGImage? {
        render(sourceIcon(appURL: appURL), size: size)
    }

    static func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b
        return simdDot(d, d).squareRoot()
    }

    static func simdDot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        (a * b).sum()
    }

    static func simdClamp(_ value: SIMD3<Double>) -> SIMD3<Double> {
        value.clamped(lowerBound: .zero, upperBound: .one)
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func hex(_ color: SIMD3<Double>) -> String {
        RGBColor(red: color.x, green: color.y, blue: color.z).hex
    }
}

struct Pixels {
    let width: Int
    let height: Int
    var data: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
    }

    func color(at offset: Int) -> SIMD3<Double> {
        let alpha = Double(data[offset + 3])
        guard alpha > 0 else { return .zero }
        return SIMD3(Double(data[offset]), Double(data[offset + 1]), Double(data[offset + 2])) / alpha
    }

    mutating func setColor(_ color: SIMD3<Double>, alpha: Double, at offset: Int) {
        let premultiplied = color * alpha * 255
        data[offset] = UInt8(min(max(premultiplied.x.rounded(), 0), 255))
        data[offset + 1] = UInt8(min(max(premultiplied.y.rounded(), 0), 255))
        data[offset + 2] = UInt8(min(max(premultiplied.z.rounded(), 0), 255))
    }

    func makeImage() -> CGImage? {
        let provider = CGDataProvider(data: Data(data) as CFData)
        return provider.flatMap {
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        }
    }
}
