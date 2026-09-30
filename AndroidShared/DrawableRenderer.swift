//
//  DrawableRenderer.swift
//  QuickLookAPKPreview
//
//  Turns an Android drawable resource (as referenced by <application android:icon>)
//  into image data. Prefers the resource's <adaptive-icon> drawn with Core Graphics
//  (full-bleed, any size) when it can be reproduced faithfully; otherwise uses a
//  prerendered bitmap shipped in the APK (a raster config of the resource, or a
//  <bitmap> alias pointing at one); failing that, draws whatever it can of the
//  compiled XML drawable tree — <adaptive-icon>, <layer-list>, <inset>, <shape>,
//  <bitmap>, <vector>, colors.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO

final class DrawableRenderer {
    private let archive: ZipArchive
    private let table: AndroidResourceTable?
    private let preferredDensity: Int
    private let masksAdaptiveIcon: Bool
    private let maxDepth = 12
    private var fileCache: [String: Data] = [:]
    /// Set while rendering when something couldn't be drawn faithfully, e.g. a
    /// missing layer, an unresolvable color or an animated drawable.
    private var isLossy = false

    private enum AttrID {
        static let src: UInt32 = 0x01010119
        static let drawable: UInt32 = 0x01010199
        static let color: UInt32 = 0x010101a5
    }
    
    /// Framework colors commonly used as adaptive-icon backgrounds; framework
    /// (0x01 package) resources aren't in the APK's own resources.arsc.
    private static let frameworkColors: [UInt32: CGColor] = [
        0x0106000b: CGColor(red: 1, green: 1, blue: 1, alpha: 1), // @android:color/white
        0x0106000c: CGColor(red: 0, green: 0, blue: 0, alpha: 1), // @android:color/black
        0x0106000d: CGColor(red: 0, green: 0, blue: 0, alpha: 0), // @android:color/transparent
    ]

    /// `masksAdaptiveIcon` clips adaptive icons to a launcher-style rounded square;
    /// without it they fill the whole image.
    init(archive: ZipArchive, table: AndroidResourceTable?, preferredDensity: Int = 480, masksAdaptiveIcon: Bool = true) {
        self.archive = archive
        self.table = table
        self.preferredDensity = preferredDensity
        self.masksAdaptiveIcon = masksAdaptiveIcon
    }

    /// Returns image data and its MIME type for a drawable value, e.g. the
    /// `android:icon` attribute value: a faithful adaptive-icon render, else a
    /// prerendered bitmap, else a best-effort (lossy) render.
    func image(for value: AXMLValue, renderSize: CGFloat = 512) -> (data: Data, mimeType: String)? {
        // An adaptive icon renders full-bleed and at any size, whereas the legacy bitmaps
        // shipped alongside it are small and carry the old launcher padding and shadow.
        // Falls back to a bitmap when the adaptive icon can't be rendered faithfully.
        var lossyAdaptivePNG: Data?
        if let adaptiveIcon = adaptiveIcon(for: value, depth: 0) {
            isLossy = false
            if let png = render(size: renderSize, { rect, dp, context in
                drawElement(adaptiveIcon, in: rect, dp: dp, context: context, depth: 1)
            }) {
                if !isLossy { return (png, "image/png") }
                lossyAdaptivePNG = png
            }
        }
        if let path = rasterPath(for: value, depth: 0),
           let data = fileData(path),
           let mimeType = Self.rasterMimeType(data) {
            return (data, mimeType)
        }
        if let png = lossyAdaptivePNG {
            return (png, "image/png")
        }
        if let png = render(size: renderSize, { rect, dp, context in
            draw(value, in: rect, dp: dp, context: context, depth: 0)
        }) {
            return (png, "image/png")
        }
        return nil
    }

    // MARK: - Resource lookup

    /// Reads an APK entry, caching it since the same files are probed repeatedly.
    private func fileData(_ path: String) -> Data? {
        if let data = fileCache[path] { return data }
        let data = archive.data(for: path)
        fileCache[path] = data
        return data
    }
    
    /// Detects raster images by content, since resource-shrunk APKs often use
    /// obfuscated file names without extensions (e.g. `res/AO`).
    private static func rasterMimeType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 4 else { return nil }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if bytes.count >= 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        return nil
    }
    
    /// Whether the APK entry at `path` is a PNG/JPEG/GIF/WebP image.
    private func isRasterPath(_ path: String) -> Bool {
        fileData(path).flatMap(Self.rasterMimeType) != nil
    }
    
    /// Parses a compiled XML resource file (AXML chunk type 0x0003).
    private func xmlRoot(_ path: String) -> AXMLElement? {
        guard let data = fileData(path), data.count >= 8, data[data.startIndex] == 0x03, data[data.startIndex + 1] == 0x00 else { return nil }
        return AXMLParser.parse(data: data)?.root
    }
    
    /// All config values of a reference, raster files first, then by density preference.
    private func candidates(for resID: UInt32) -> [AXMLValue] {
        let values = table?.resolveAll(resID, preferredDensity: preferredDensity) ?? []
        let raster = values.filter { if case .string(let s) = $0 { return isRasterPath(s) }; return false }
        let others = values.filter { if case .string(let s) = $0 { return !isRasterPath(s) }; return true }
        return raster + others
    }

    /// Finds an in-APK raster file the drawable is equivalent to, without rendering:
    /// the file itself, a raster config of the resource, or a `<bitmap>` alias.
    private func rasterPath(for value: AXMLValue, depth: Int) -> String? {
        guard depth < maxDepth else { return nil }
        switch value {
        case .string(let path):
            if isRasterPath(path) {
                return path
            }
            guard let root = xmlRoot(path),
                  root.name == "bitmap" || root.name == "nine-patch",
                  let src = attribute(root, "src", id: AttrID.src) else { return nil }
            return rasterPath(for: src, depth: depth + 1)
        case .reference(let resID):
            for candidate in candidates(for: resID) {
                if let path = rasterPath(for: candidate, depth: depth + 1) {
                    return path
                }
            }
            return nil
        default:
            return nil
        }
    }

    /// Finds the `<adaptive-icon>` element among the configs of a drawable, if any.
    private func adaptiveIcon(for value: AXMLValue, depth: Int) -> AXMLElement? {
        guard depth < maxDepth else { return nil }
        switch value {
        case .string(let path):
            guard let root = xmlRoot(path), root.name == "adaptive-icon" else { return nil }
            return root
        case .reference(let resID):
            for candidate in table?.resolveAll(resID, preferredDensity: preferredDensity) ?? [] {
                if let root = adaptiveIcon(for: candidate, depth: depth + 1) {
                    return root
                }
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Rendering

    /// Renders `drawing` into a square PNG. The closure gets the target rect, the
    /// points-per-dp scale, and a top-left-origin, Y-down context.
    private func render(size: CGFloat, _ drawing: (CGRect, CGFloat, CGContext) -> Bool) -> Data? {
        let pixels = Int(size)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixels,
                height: pixels,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        // Top-left-origin, Y-down, matching Android's drawable coordinate space.
        context.translateBy(x: 0, y: size)
        context.scaleBy(x: 1, y: -1)

        // A legacy launcher icon is 48dp.
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        guard drawing(rect, size / 48, context),
              let cgImage = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// Draws a drawable value into `rect`. `dp` is the number of points per dp,
    /// used to scale dimension attributes (insets, corner radii).
    @discardableResult
    private func draw(_ value: AXMLValue, in rect: CGRect, dp: CGFloat, context: CGContext, depth: Int) -> Bool {
        guard depth < maxDepth else { return false }
        if let color = AndroidColor.decode(value) ?? frameworkColor(value) {
            context.setFillColor(color)
            context.fill(rect)
            return true
        }
        switch value {
        case .string(let path):
            if isRasterPath(path) {
                return drawRaster(path: path, in: rect, context: context)
            }
            guard let root = xmlRoot(path) else { return false }
            return drawElement(root, in: rect, dp: dp, context: context, depth: depth + 1)
        case .reference(let resID):
            return candidates(for: resID).contains {
                draw($0, in: rect, dp: dp, context: context, depth: depth + 1)
            }
        default:
            return false
        }
    }

    /// Draws the bitmap at `path` stretched to `rect`.
    private func drawRaster(path: String, in rect: CGRect, context: CGContext) -> Bool {
        guard let data = fileData(path),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        // CGContext.draw expects a Y-up space, so flip locally around the target rect.
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        return true
    }

    /// Draws a parsed drawable XML element into `rect`, dispatching on its tag.
    /// Unknown wrapper tags draw their child drawable and mark the render lossy.
    private func drawElement(_ element: AXMLElement, in rect: CGRect, dp: CGFloat, context: CGContext, depth: Int) -> Bool {
        guard depth < maxDepth else { return false }
        switch element.name {
        case "vector":
            return VectorDrawableRenderer.draw(element, in: rect, context: context, resolveColor: { [self] in
                resolveColor($0, depth: depth + 1)
            }, resolveGradient: { [self] in
                resolveGradient($0, depth: depth + 1)
            }, unsupported: { [self] in
                isLossy = true
            })

        case "bitmap", "nine-patch":
            guard let src = attribute(element, "src", id: AttrID.src) else { return false }
            return draw(src, in: rect, dp: dp, context: context, depth: depth + 1)

        case "adaptive-icon":
            return drawAdaptiveIcon(element, in: rect, context: context, depth: depth)

        case "layer-list":
            var drew = false
            for item in element.children where item.name == "item" {
                let itemRect = insetRect(rect, element: item, dp: dp, prefix: "")
                if drawChildDrawable(of: item, in: itemRect, dp: dp, context: context, depth: depth + 1) {
                    drew = true
                }
            }
            return drew

        case "inset":
            let innerRect = insetRect(rect, element: element, dp: dp, prefix: "inset")
            return drawChildDrawable(of: element, in: innerRect, dp: dp, context: context, depth: depth + 1)

        case "shape":
            return drawShape(element, in: rect, dp: dp, context: context, depth: depth)

        case "color":
            guard let value = attribute(element, "color", id: AttrID.color),
                  let color = resolveColor(value, depth: depth + 1) else {
                isLossy = true
                return false
            }
            context.setFillColor(color)
            context.fill(rect)
            return true

        case "selector", "level-list":
            // Use the default (stateless) item, falling back to the first one.
            let items = element.children.filter { $0.name == "item" }
            let item = items.first { !$0.attributes.contains { $0.name.hasPrefix("state_") } } ?? items.first
            guard let item else { return false }
            return drawChildDrawable(of: item, in: rect, dp: dp, context: context, depth: depth + 1)

        default:
            // Wrappers such as <animated-vector>, <clip>, <scale>, <rotate>, <ripple>:
            // draw the wrapped drawable as-is. Only a ripple looks the same at rest.
            if element.name != "ripple" { isLossy = true }
            return drawChildDrawable(of: element, in: rect, dp: dp, context: context, depth: depth + 1)
        }
    }

    /// Draws the drawable held by a container element, given either as an
    /// `android:drawable` attribute or as a nested child element.
    private func drawChildDrawable(of element: AXMLElement, in rect: CGRect, dp: CGFloat, context: CGContext, depth: Int) -> Bool {
        if let value = attribute(element, "drawable", id: AttrID.drawable) {
            return draw(value, in: rect, dp: dp, context: context, depth: depth)
        }
        return element.children.contains {
            drawElement($0, in: rect, dp: dp, context: context, depth: depth)
        }
    }

    /// Draws the background and foreground layers. Layers are 108dp, of which the
    /// launcher shows the center 72dp (`rect`) through a mask; approximated with a
    /// rounded square, or the plain square when `masksAdaptiveIcon` is off.
    /// A layer that fails to draw marks the render lossy.
    private func drawAdaptiveIcon(_ element: AXMLElement, in rect: CGRect, context: CGContext, depth: Int) -> Bool {
        let layerRect = rect.insetBy(dx: -rect.width / 4, dy: -rect.height / 4)
        let layerDP = layerRect.width / 108

        context.saveGState()
        defer { context.restoreGState() }
        let radius = masksAdaptiveIcon ? rect.width * 0.225 : 0
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()

        var drew = false
        for layerName in ["background", "foreground"] {
            guard let layer = element.firstChild(named: layerName) else { continue }
            if drawChildDrawable(of: layer, in: layerRect, dp: layerDP, context: context, depth: depth + 1) {
                drew = true
            } else {
                isLossy = true // e.g. a layer bitmap that lives in a density split APK
            }
        }
        return drew
    }

    // MARK: - Shapes

    /// Draws a `<shape>` (rectangle with optional corner radius, or oval) filled
    /// with its `<solid>` color and/or `<gradient>`.
    private func drawShape(_ element: AXMLElement, in rect: CGRect, dp: CGFloat, context: CGContext, depth: Int) -> Bool {
        let path: CGPath
        switch intAttribute(element, "shape") ?? 0 {
        case 0: // rectangle
            var radius = element.firstChild(named: "corners")
                .flatMap { $0.attribute(named: "radius") }
                .flatMap { dimension($0.value, relativeTo: min(rect.width, rect.height), dp: dp) } ?? 0
            radius = min(radius, min(rect.width, rect.height) / 2)
            path = radius > 0
                ? CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                : CGPath(rect: rect, transform: nil)
        case 1: // oval
            path = CGPath(ellipseIn: rect, transform: nil)
        default: // line / ring aren't meaningful as icon backgrounds
            isLossy = true
            return false
        }

        var drew = false
        if let solid = element.firstChild(named: "solid"),
           let value = attribute(solid, "color", id: AttrID.color) {
            guard let color = resolveColor(value, depth: depth + 1) else {
                isLossy = true
                return false
            }
            context.saveGState()
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
            drew = true
        }
        if let gradient = element.firstChild(named: "gradient") {
            context.saveGState()
            context.addPath(path)
            context.clip()
            if drawGradient(gradient, in: rect, dp: dp, context: context, depth: depth) {
                drew = true
            } else {
                isLossy = true
            }
            context.restoreGState()
        }
        return drew
    }

    /// Fills the current clip with a shape `<gradient>`: linear by `angle`, or radial
    /// from `centerX`/`centerY` (fractions of `rect`); sweep is approximated as linear.
    private func drawGradient(_ element: AXMLElement, in rect: CGRect, dp: CGFloat, context: CGContext, depth: Int) -> Bool {
        let color: (String) -> CGColor? = { [self] name in
            element.attribute(named: name).flatMap { resolveColor($0.value, depth: depth + 1) }
        }
        guard let start = color("startColor"), let end = color("endColor") else { return false }
        var colors = [start, end]
        var locations: [CGFloat] = [0, 1]
        if let center = color("centerColor") {
            colors = [start, center, end]
            locations = [0, 0.5, 1]
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) else { return false }
        let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

        let centerX = VectorDrawableRenderer.floatAttribute(element, "centerX") ?? 0.5
        let centerY = VectorDrawableRenderer.floatAttribute(element, "centerY") ?? 0.5
        let center = CGPoint(x: rect.minX + rect.width * centerX, y: rect.minY + rect.height * centerY)

        switch intAttribute(element, "type") ?? 0 {
        case 1: // radial
            let radius = element.attribute(named: "gradientRadius")
                .flatMap { dimension($0.value, relativeTo: min(rect.width, rect.height), dp: dp)
                    ?? VectorDrawableRenderer.floatAttribute(element, "gradientRadius").map { $0 * dp } }
                ?? rect.width / 2
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: options)
        default: // linear (sweep is approximated as linear)
            // Android angles are counter-clockwise from left-to-right; Y points down here.
            let angle = (VectorDrawableRenderer.floatAttribute(element, "angle") ?? 0) * .pi / 180
            let direction = CGPoint(x: cos(angle), y: -sin(angle))
            let halfLength = (abs(direction.x) * rect.width + abs(direction.y) * rect.height) / 2
            let mid = CGPoint(x: rect.midX, y: rect.midY)
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: mid.x - direction.x * halfLength, y: mid.y - direction.y * halfLength),
                end: CGPoint(x: mid.x + direction.x * halfLength, y: mid.y + direction.y * halfLength),
                options: options
            )
        }
        return true
    }

    // MARK: - Attribute values

    /// An attribute's value, looked up by resource ID first, since resource-shrunk  APKs may strip attribute names.
    private func attribute(_ element: AXMLElement, _ name: String, id: UInt32) -> AXMLValue? {
        (element.attribute(id: id) ?? element.attribute(named: name))?.value
    }

    /// An integer (or enum) attribute's value.
    private func intAttribute(_ element: AXMLElement, _ name: String) -> Int? {
        guard case .intValue(let value)? = element.attribute(named: name)?.value else { return nil }
        return Int(value)
    }

    /// Resolves a color value, following `@color/...` references and taking the  default color of a color state list.
    private func resolveColor(_ value: AXMLValue, depth: Int) -> CGColor? {
        guard depth < maxDepth else { return nil }
        if let color = AndroidColor.decode(value) ?? frameworkColor(value) { return color }
        switch value {
        case .reference(let resID):
            for candidate in table?.resolveAll(resID, preferredDensity: preferredDensity) ?? [] {
                if let color = resolveColor(candidate, depth: depth + 1) { return color }
            }
            return nil
        case .string(let path):
            guard let root = xmlRoot(path), root.name == "selector" else { return nil }
            let items = root.children.filter { $0.name == "item" }
            let item = items.first { !$0.attributes.contains { $0.name.hasPrefix("state_") } } ?? items.first
            return item.flatMap { attribute($0, "color", id: AttrID.color) }.flatMap { resolveColor($0, depth: depth + 1) }
        default:
            return nil
        }
    }

    /// Resolves a reference to a compiled `<gradient>` resource (a vector path's gradient fill, which aapt extracts into its own XML file).
    private func resolveGradient(_ value: AXMLValue, depth: Int) -> AXMLElement? {
        guard depth < maxDepth else { return nil }
        switch value {
        case .reference(let resID):
            for candidate in table?.resolveAll(resID, preferredDensity: preferredDensity) ?? [] {
                if let gradient = resolveGradient(candidate, depth: depth + 1) { return gradient }
            }
            return nil
        case .string(let path):
            guard let root = xmlRoot(path), root.name == "gradient" else { return nil }
            return root
        default:
            return nil
        }
    }

    /// Colors for the few `@android:color/...` references listed in `frameworkColors`.
    private func frameworkColor(_ value: AXMLValue) -> CGColor? {
        guard case .reference(let resID) = value else { return nil }
        return Self.frameworkColors[resID]
    }
    
    /// Insets `rect` by the element's `<prefix>Left/Top/Right/Bottom` attributes
    /// (`left`/`top`/... for layer-list items, `insetLeft`/... plus `inset` for <inset>).
    private func insetRect(_ rect: CGRect, element: AXMLElement, dp: CGFloat, prefix: String) -> CGRect {
        func inset(_ side: String, relativeTo size: CGFloat) -> CGFloat {
            let name = prefix.isEmpty ? side.lowercased() : prefix + side
            if let attr = element.attribute(named: name) ?? (prefix.isEmpty ? nil : element.attribute(named: prefix)) {
                return dimension(attr.value, relativeTo: size, dp: dp) ?? 0
            }
            return 0
        }
        let left = inset("Left", relativeTo: rect.width)
        let top = inset("Top", relativeTo: rect.height)
        let right = inset("Right", relativeTo: rect.width)
        let bottom = inset("Bottom", relativeTo: rect.height)
        let result = CGRect(x: rect.minX + left, y: rect.minY + top, width: rect.width - left - right, height: rect.height - top - bottom)
        return result.width > 0 && result.height > 0 ? result : rect
    }

    /// Decodes a `TYPE_DIMENSION` (to points) or `TYPE_FRACTION` (of `size`) value.
    private func dimension(_ value: AXMLValue, relativeTo size: CGFloat, dp: CGFloat) -> CGFloat? {
        guard case .other(let type, let data) = value, type == 0x05 || type == 0x06 else { return nil }
        // Res_value complex encoding: 24-bit mantissa, 2-bit radix, 4-bit unit.
        let radixMultipliers: [CGFloat] = [1.0 / 256, 1.0 / 32768, 1.0 / 8388608, 1.0 / 2147483648]
        let number = CGFloat(Int32(bitPattern: data & 0xFFFF_FF00)) * radixMultipliers[Int((data >> 4) & 0x3)]
        let unit = data & 0xF
        if type == 0x06 {
            return number * size // fraction of self or parent; both map to the drawable bounds here
        }
        switch unit {
        case 0: return number * dp / 3 // px, assuming xxhdpi
        case 1, 2: return number * dp // dp, sp
        default: return nil
        }
    }
}
