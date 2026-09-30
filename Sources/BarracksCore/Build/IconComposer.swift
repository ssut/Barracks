import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum IconComposer {
    static let icnsSizes = [16, 32, 64, 128, 256, 512, 1024]

    public static func initial(of name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    static func makeContext(size: Int) -> CGContext? {
        CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    static func drawing(size: Int, _ body: (CGFloat) -> Void) -> CGImage? {
        guard let context = makeContext(size: size) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        body(CGFloat(size))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    static func tile(in side: CGFloat) -> (rect: NSRect, path: NSBezierPath) {
        let inset = side * 0.098
        let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        return (rect, NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225))
    }

    static func fillTile(_ path: NSBezierPath, rect: NSRect, top: NSColor, bottom: NSColor, side: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = side * 0.02
        shadow.shadowOffset = NSSize(width: 0, height: -side * 0.008)
        shadow.set()
        bottom.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: -90)
        NSColor.white.withAlphaComponent(0.18).setStroke()
        path.lineWidth = max(1, side * 0.004)
        path.stroke()
    }

    static func tentPath(baseCenter: NSPoint, width: CGFloat, height: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: baseCenter.x - width / 2, y: baseCenter.y))
        path.line(to: NSPoint(x: baseCenter.x, y: baseCenter.y + height))
        path.line(to: NSPoint(x: baseCenter.x + width / 2, y: baseCenter.y))
        path.close()
        path.lineJoinStyle = .round
        return path
    }

    public static func renderProfileIcon(color: ProfileColor, name: String, provider: AppProvider = .claude, size: Int) -> CGImage? {
        renderProfileIcon(tint: .preset(color), name: name, provider: provider, size: size)
    }

    public static func renderProfileIcon(tint: ProfileTint, name: String, provider: AppProvider = .claude, size: Int) -> CGImage? {
        drawing(size: size) { side in
            let (rect, path) = tile(in: side)
            let rgb = tint.rgb
            let base = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
            let top = base.blended(withFraction: 0.22, of: .white) ?? base
            let bottom = base.blended(withFraction: 0.28, of: .black) ?? base
            fillTile(path, rect: rect, top: top, bottom: bottom, side: side)

            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let ridge = tentPath(baseCenter: NSPoint(x: rect.midX, y: rect.minY - rect.height * 0.02), width: rect.width * 1.25, height: rect.height * 0.34)
            NSColor.black.withAlphaComponent(0.12).setFill()
            ridge.fill()
            NSGraphicsContext.restoreGraphicsState()

            let letter = initial(of: name)
            let font = NSFont.systemFont(ofSize: rect.height * 0.5, weight: .heavy)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
            ]
            let text = NSAttributedString(string: letter, attributes: attributes)
            let bounds = text.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading])
            let origin = NSPoint(x: rect.minX, y: rect.midY - bounds.height / 2 + rect.height * 0.06)
            text.draw(with: NSRect(origin: origin, size: NSSize(width: rect.width, height: bounds.height)), options: [.usesLineFragmentOrigin, .usesFontLeading])

            let markY = rect.minY + rect.height * 0.16
            switch provider {
            case .claude:
                let dotRadius = rect.width * 0.045
                for index in -1...1 {
                    let x = rect.midX + CGFloat(index) * dotRadius * 3.2
                    let dot = NSBezierPath(ovalIn: NSRect(x: x - dotRadius, y: markY - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
                    NSColor.white.withAlphaComponent(index == 0 ? 0.95 : 0.55).setFill()
                    dot.fill()
                }
            case .chatgpt:
                let radius = rect.width * 0.075
                let ring = NSBezierPath(ovalIn: NSRect(x: rect.midX - radius, y: markY - radius, width: radius * 2, height: radius * 2))
                ring.lineWidth = rect.width * 0.03
                NSColor.white.withAlphaComponent(0.9).setStroke()
                ring.stroke()
            }
        }
    }

    public static func renderAppIcon(size: Int) -> CGImage? {
        drawing(size: size) { side in
            let (rect, path) = tile(in: side)
            let top = NSColor(srgbRed: 0.20, green: 0.17, blue: 0.14, alpha: 1)
            let bottom = NSColor(srgbRed: 0.09, green: 0.08, blue: 0.07, alpha: 1)
            fillTile(path, rect: rect, top: top, bottom: bottom, side: side)

            let groundY = rect.minY + rect.height * 0.27
            let ground = NSBezierPath(roundedRect: NSRect(x: rect.minX + rect.width * 0.12, y: groundY - rect.height * 0.035, width: rect.width * 0.76, height: rect.height * 0.035), xRadius: rect.height * 0.0175, yRadius: rect.height * 0.0175)
            NSColor(srgbRed: 0.93, green: 0.88, blue: 0.80, alpha: 0.9).setFill()
            ground.fill()

            let tents: [(ProfileColor, CGFloat, CGFloat)] = [(.teal, -0.24, 0.30), (.clay, 0, 0.44), (.indigo, 0.24, 0.30)]
            for (color, offset, heightFactor) in tents.sorted(by: { $0.2 < $1.2 }) {
                let (r, g, b) = color.rgb
                let fill = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
                let width = rect.width * (heightFactor > 0.4 ? 0.46 : 0.36)
                let tent = tentPath(baseCenter: NSPoint(x: rect.midX + rect.width * offset, y: groundY), width: width, height: rect.height * heightFactor)
                fill.setFill()
                tent.fill()
                NSColor(srgbRed: 0.09, green: 0.08, blue: 0.07, alpha: 1).setStroke()
                tent.lineWidth = side * 0.012
                tent.stroke()
                let doorHeight = rect.height * heightFactor * 0.42
                let door = tentPath(baseCenter: NSPoint(x: rect.midX + rect.width * offset, y: groundY), width: width * 0.28, height: doorHeight)
                NSColor.black.withAlphaComponent(0.35).setFill()
                door.fill()
            }

            let flagPoleX = rect.midX
            let poleTop = groundY + rect.height * 0.44 + rect.height * 0.14
            let pole = NSBezierPath()
            pole.move(to: NSPoint(x: flagPoleX, y: groundY + rect.height * 0.43))
            pole.line(to: NSPoint(x: flagPoleX, y: poleTop))
            pole.lineWidth = side * 0.012
            pole.lineCapStyle = .round
            NSColor(srgbRed: 0.93, green: 0.88, blue: 0.80, alpha: 1).setStroke()
            pole.stroke()
            let flag = NSBezierPath()
            flag.move(to: NSPoint(x: flagPoleX, y: poleTop))
            flag.line(to: NSPoint(x: flagPoleX + rect.width * 0.11, y: poleTop - rect.height * 0.035))
            flag.line(to: NSPoint(x: flagPoleX, y: poleTop - rect.height * 0.07))
            flag.close()
            let (ar, ag, ab) = ProfileColor.amber.rgb
            NSColor(srgbRed: ar, green: ag, blue: ab, alpha: 1).setFill()
            flag.fill()
        }
    }

    public static func renderProfileIcon(tint: ProfileTint, name: String, provider: AppProvider, sourceApp: URL?, size: Int) -> CGImage? {
        if let sourceApp, let recolored = IconRecolor.profileIcon(appURL: sourceApp, tint: tint, size: size) {
            return recolored
        }
        return renderProfileIcon(tint: tint, name: name, provider: provider, size: size)
    }

    public static func profileImage(tint: ProfileTint, name: String, provider: AppProvider = .claude, sourceApp: URL? = nil, points: Int = 64) -> NSImage {
        let pixels = points * 2
        guard let image = renderProfileIcon(tint: tint, name: name, provider: provider, sourceApp: sourceApp, size: pixels) else { return NSImage() }
        return NSImage(cgImage: image, size: NSSize(width: points, height: points))
    }

    public static func appImage(points: Int = 128) -> NSImage {
        guard let image = renderAppIcon(size: points * 2) else { return NSImage() }
        return NSImage(cgImage: image, size: NSSize(width: points, height: points))
    }

    public static func writeIcns(to url: URL, render: (Int) -> CGImage?) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, icnsSizes.count, nil) else {
            throw BarracksError.installFailed("cannot create icon file")
        }
        var added = 0
        for size in icnsSizes {
            guard let image = render(size) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            added += 1
        }
        guard added > 0, CGImageDestinationFinalize(destination) else {
            throw BarracksError.installFailed("cannot write icon file")
        }
        Log.info("icon.written", ["path": url.lastPathComponent, "sizes": String(added)])
    }

    public static func writeProfileIcns(tint: ProfileTint, name: String, provider: AppProvider = .claude, sourceApp: URL? = nil, to url: URL) throws {
        let recolor = sourceApp.flatMap { IconRecolor.palette(appURL: $0) } != nil
        Log.info("icon.profile_style", ["style": recolor ? "recolored_app_icon" : "generated", "provider": provider.rawValue])
        try writeIcns(to: url) { renderProfileIcon(tint: tint, name: name, provider: provider, sourceApp: recolor ? sourceApp : nil, size: $0) }
    }

    public static func writeAppIcns(to url: URL) throws {
        try writeIcns(to: url) { renderAppIcon(size: $0) }
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw BarracksError.installFailed("cannot create png")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw BarracksError.installFailed("cannot write png") }
    }
}
