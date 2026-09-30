//
//  VectorDrawableRenderer.swift
//  QuickLookAPKPreview
//
//  Draws a compiled Android VectorDrawable XML resource (the same AXML binary
//  chunk format as AndroidManifest.xml) into a Core Graphics context. Used by
//  DrawableRenderer for vector app icons and adaptive-icon layers.
//

import AppKit
import CoreGraphics
import Foundation

enum VectorDrawableRenderer {
    /// How a path is filled or stroked.
    private enum Paint {
        case color(CGColor)
        /// Positioned in the path's own (viewport) coordinates.
        case linearGradient(CGGradient, start: CGPoint, end: CGPoint)
        case radialGradient(CGGradient, center: CGPoint, radius: CGFloat)
    }

    private struct VectorPath {
        let path: CGPath
        let transform: CGAffineTransform
        /// `<clip-path>`s in effect, already in viewport coordinates.
        let clips: [CGPath]
        let fill: Paint?
        let fillAlpha: CGFloat
        let fillRule: CGPathFillRule
        let stroke: Paint?
        let strokeAlpha: CGFloat
        let strokeWidth: CGFloat
        let lineCap: CGLineCap
        let lineJoin: CGLineJoin
        let miterLimit: CGFloat
    }
    
    /// Draws a parsed `<vector>` element scaled to fill `rect` of `context`, which must
    /// use a top-left-origin, Y-down coordinate space. `resolveColor` resolves color
    /// values the drawable can't decode itself (e.g. `@color/...` references), and
    /// `resolveGradient` resolves a fill/stroke reference to a compiled `<gradient>`
    /// element (aapt moves inline `<aapt:attr>` gradients into their own resource).
    /// `unsupported` is called when the drawing can't be reproduced faithfully
    /// (unresolvable colors, sweep or tiled gradients, trimmed paths).
    /// Returns false if the element isn't a vector or has nothing to draw.
    static func draw(_ root: AXMLElement, in rect: CGRect, context: CGContext, resolveColor: (AXMLValue) -> CGColor?, resolveGradient: (AXMLValue) -> AXMLElement?, unsupported: () -> Void) -> Bool {
        guard root.name == "vector" else { return false }
        
        let viewportWidth = floatAttribute(root, "viewportWidth") ?? 24
        let viewportHeight = floatAttribute(root, "viewportHeight") ?? 24
        guard viewportWidth > 0, viewportHeight > 0 else { return false }
        
        var paths: [VectorPath] = []
        collectPaths(root, transform: .identity, clips: [], resolveColor: resolveColor, resolveGradient: resolveGradient, unsupported: unsupported, into: &paths)
        guard !paths.isEmpty else { return false }
        
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / viewportWidth, y: rect.height / viewportHeight)
        if let alpha = floatAttribute(root, "alpha") {
            context.setAlpha(alpha)
        }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }
        
        for item in paths {
            context.saveGState()
            for clip in item.clips {
                context.addPath(clip)
                context.clip()
            }
            context.concatenate(item.transform)
            if let fill = item.fill {
                context.addPath(item.path)
                paint(fill, alpha: item.fillAlpha, context: context) {
                    context.fillPath(using: item.fillRule)
                } clip: {
                    context.clip(using: item.fillRule)
                }
            }
            if let stroke = item.stroke, item.strokeWidth > 0 {
                context.setLineWidth(item.strokeWidth)
                context.setLineCap(item.lineCap)
                context.setLineJoin(item.lineJoin)
                context.setMiterLimit(item.miterLimit)
                context.addPath(item.path)
                paint(stroke, alpha: item.strokeAlpha, context: context) {
                    context.strokePath()
                } clip: {
                    context.replacePathWithStrokedPath()
                    context.clip()
                }
            }
            context.restoreGState()
        }
        return true
    }

    /// Paints the context's current path: a solid color via `draw`, a gradient by
    /// clipping to the path via `clip` and then filling the clip with the gradient.
    private static func paint(_ paint: Paint, alpha: CGFloat, context: CGContext, draw: () -> Void, clip: () -> Void) {
        let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        switch paint {
        case .color(let color):
            context.setFillColor(color.copy(alpha: color.alpha * alpha) ?? color)
            context.setStrokeColor(color.copy(alpha: color.alpha * alpha) ?? color)
            draw()
        case .linearGradient(let gradient, let start, let end):
            context.saveGState()
            clip()
            context.setAlpha(alpha)
            context.drawLinearGradient(gradient, start: start, end: end, options: extend)
            context.restoreGState()
        case .radialGradient(let gradient, let center, let radius):
            context.saveGState()
            clip()
            context.setAlpha(alpha)
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: extend)
            context.restoreGState()
        }
    }

    /// Builds a paint from a compiled vector `<gradient>` element: colors come from
    /// `<item android:offset android:color>` children, or from start/center/end colors.
    private static func gradientPaint(_ element: AXMLElement, resolveColor: (AXMLValue) -> CGColor?, unsupported: () -> Void) -> Paint? {
        func color(_ value: AXMLValue) -> CGColor? {
            AndroidColor.decode(value) ?? resolveColor(value)
        }
        var colors: [CGColor] = []
        var locations: [CGFloat] = []
        let items = element.children.filter { $0.name == "item" }
        if !items.isEmpty {
            for item in items {
                guard let value = item.attribute(named: "color")?.value, let itemColor = color(value) else {
                    unsupported()
                    return nil
                }
                colors.append(itemColor)
                locations.append(floatAttribute(item, "offset") ?? 0)
            }
        } else {
            guard let start = element.attribute(named: "startColor").flatMap({ color($0.value) }),
                  let end = element.attribute(named: "endColor").flatMap({ color($0.value) }) else {
                unsupported()
                return nil
            }
            colors = [start, end]
            locations = [0, 1]
            if let center = element.attribute(named: "centerColor").flatMap({ color($0.value) }) {
                colors.insert(center, at: 1)
                locations.insert(0.5, at: 1)
            }
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) else {
            unsupported()
            return nil
        }
        if (intAttribute(element, "tileMode") ?? 0) != 0 {
            unsupported() // repeat / mirror tiling; drawn as clamp
        }

        let point = { (x: String, y: String) in
            CGPoint(x: floatAttribute(element, x) ?? 0, y: floatAttribute(element, y) ?? 0)
        }
        switch intAttribute(element, "type") ?? 0 {
        case 0:
            return .linearGradient(gradient, start: point("startX", "startY"), end: point("endX", "endY"))
        case 1:
            return .radialGradient(gradient, center: point("centerX", "centerY"), radius: floatAttribute(element, "gradientRadius") ?? 0)
        default:
            unsupported() // sweep
            return nil
        }
    }
    
    // MARK: - AXML element inspection
    
    /// A float (or integer) attribute's value.
    static func floatAttribute(_ element: AXMLElement, _ name: String) -> CGFloat? {
        guard let attr = element.attribute(named: name) else { return nil }
        switch attr.value {
        case .intValue(let i):
            return CGFloat(i)
        case .other(let type, let data) where type == 0x04: // TYPE_FLOAT
            return CGFloat(Float(bitPattern: data))
        default:
            return nil
        }
    }
    
    /// An integer (or enum) attribute's value.
    private static func intAttribute(_ element: AXMLElement, _ name: String) -> Int? {
        guard case .intValue(let value)? = element.attribute(named: name)?.value else { return nil }
        return Int(value)
    }
    
    /// Walks the element tree, collecting each `<path>` along with the accumulated
    /// transform of its enclosing `<group>`s.
    private static func collectPaths(_ element: AXMLElement, transform: CGAffineTransform, clips: [CGPath], resolveColor: (AXMLValue) -> CGColor?, resolveGradient: (AXMLValue) -> AXMLElement?, unsupported: () -> Void, into paths: inout [VectorPath]) {
        var transform = transform
        switch element.name {
        case "group":
            transform = groupTransform(element).concatenating(transform)
        case "path":
            guard case .string(let pathData)? = element.attribute(named: "pathData")?.value,
                  let path = SVGPathParser.parse(pathData) else { break }
            if (floatAttribute(element, "trimPathStart") ?? 0) > 0 || (floatAttribute(element, "trimPathEnd") ?? 1) < 1 {
                unsupported()
            }
            // An absent fill or stroke color means that part isn't drawn.
            func paint(_ name: String) -> Paint? {
                guard let value = element.attribute(named: name)?.value else { return nil }
                if let color = AndroidColor.decode(value) ?? resolveColor(value) { return .color(color) }
                if let gradient = resolveGradient(value) {
                    return gradientPaint(gradient, resolveColor: resolveColor, unsupported: unsupported)
                }
                unsupported()
                return nil
            }
            paths.append(VectorPath(
                path: path,
                transform: transform,
                clips: clips,
                fill: paint("fillColor"),
                fillAlpha: floatAttribute(element, "fillAlpha") ?? 1,
                fillRule: intAttribute(element, "fillType") == 1 ? .evenOdd : .winding,
                stroke: paint("strokeColor"),
                strokeAlpha: floatAttribute(element, "strokeAlpha") ?? 1,
                strokeWidth: floatAttribute(element, "strokeWidth") ?? 0,
                lineCap: [.butt, .round, .square][min(max(intAttribute(element, "strokeLineCap") ?? 0, 0), 2)],
                lineJoin: [.miter, .round, .bevel][min(max(intAttribute(element, "strokeLineJoin") ?? 0, 0), 2)],
                miterLimit: floatAttribute(element, "strokeMiterLimit") ?? 4
            ))
        default:
            break
        }
        // A <clip-path> clips the siblings that follow it within its group.
        var clips = clips
        for child in element.children {
            if child.name == "clip-path" {
                var clipTransform = transform
                if case .string(let pathData)? = child.attribute(named: "pathData")?.value,
                   let clip = SVGPathParser.parse(pathData)?.copy(using: &clipTransform) {
                    clips.append(clip)
                }
                continue
            }
            collectPaths(child, transform: transform, clips: clips, resolveColor: resolveColor, resolveGradient: resolveGradient, unsupported: unsupported, into: &paths)
        }
    }
    
    /// A `<group>`'s local transform, composed the way Android's VectorDrawable does:
    /// move the pivot to the origin, scale, rotate, then move back and translate.
    private static func groupTransform(_ group: AXMLElement) -> CGAffineTransform {
        let pivotX = floatAttribute(group, "pivotX") ?? 0
        let pivotY = floatAttribute(group, "pivotY") ?? 0
        let scaleX = floatAttribute(group, "scaleX") ?? 1
        let scaleY = floatAttribute(group, "scaleY") ?? 1
        let rotation = floatAttribute(group, "rotation") ?? 0
        let translateX = floatAttribute(group, "translateX") ?? 0
        let translateY = floatAttribute(group, "translateY") ?? 0
        return CGAffineTransform(translationX: -pivotX, y: -pivotY)
            .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
            .concatenating(CGAffineTransform(rotationAngle: rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: translateX + pivotX, y: translateY + pivotY))
    }
}

/// Decodes inline Android color values (`TYPE_INT_COLOR_*` or `#RRGGBB` strings).
enum AndroidColor {
    /// The color for an inline color value; nil for references and other types.
    static func decode(_ value: AXMLValue) -> CGColor? {
        switch value {
        case .other(let type, let data):
            switch type {
            case 0x1c: // TYPE_INT_COLOR_ARGB8
                return fromARGB8(data)
            case 0x1d: // TYPE_INT_COLOR_RGB8
                return fromARGB8(0xFF00_0000 | data)
            case 0x1e: // TYPE_INT_COLOR_ARGB4
                return fromARGB8(expandShortColor(data, hasAlpha: true))
            case 0x1f: // TYPE_INT_COLOR_RGB4
                return fromARGB8(expandShortColor(data, hasAlpha: false))
            default:
                return nil
            }
        case .string(let s):
            return fromHexString(s)
        default:
            return nil
        }
    }
    
    /// An sRGB color from a packed 0xAARRGGBB value.
    private static func fromARGB8(_ value: UInt32) -> CGColor {
        let a = CGFloat((value >> 24) & 0xFF) / 255
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return CGColor(red: r, green: g, blue: b, alpha: a)
    }
    
    /// Expands a 4-bit-per-channel color (#ARGB / #RGB) to 0xAARRGGBB.
    private static func expandShortColor(_ value: UInt32, hasAlpha: Bool) -> UInt32 {
        func expand(_ nibble: UInt32) -> UInt32 { (nibble << 4) | nibble }
        let a: UInt32 = hasAlpha ? (value >> 12) & 0xF : 0xF
        let r: UInt32 = (value >> 8) & 0xF
        let g: UInt32 = (value >> 4) & 0xF
        let b: UInt32 = value & 0xF
        return (expand(a) << 24) | (expand(r) << 16) | (expand(g) << 8) | expand(b)
    }
    
    /// Parses a `#RRGGBB` or `#AARRGGBB` string.
    private static func fromHexString(_ string: String) -> CGColor? {
        var hex = string
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard let value = UInt32(hex, radix: 16) else { return nil }
        switch hex.count {
        case 6: return fromARGB8(0xFF00_0000 | value)
        case 8: return fromARGB8(value)
        default: return nil
        }
    }
}

/// Parses the SVG-compatible path-data mini-language used by VectorDrawable's
/// `android:pathData` attribute into a `CGPath`.
enum SVGPathParser {
    /// Parses path data; stops at the first malformed command, keeping what was parsed.
    /// Returns nil if nothing was drawn.
    static func parse(_ pathData: String) -> CGPath? {
        let chars = Array(pathData)
        var index = 0
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastCommand: Character = " "
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        
        func skipSeparators() {
            while index < chars.count, chars[index] == " " || chars[index] == "," || chars[index] == "\n" || chars[index] == "\t" || chars[index] == "\r" {
                index += 1
            }
        }
        
        func readNumber() -> CGFloat? {
            skipSeparators()
            guard index < chars.count else { return nil }
            var text = ""
            if chars[index] == "+" || chars[index] == "-" {
                text.append(chars[index]); index += 1
            }
            while index < chars.count, chars[index].isNumber {
                text.append(chars[index]); index += 1
            }
            if index < chars.count, chars[index] == "." {
                text.append("."); index += 1
                while index < chars.count, chars[index].isNumber {
                    text.append(chars[index]); index += 1
                }
            }
            if index < chars.count, chars[index] == "e" || chars[index] == "E" {
                var exponent = String(chars[index])
                var probe = index + 1
                if probe < chars.count, chars[probe] == "+" || chars[probe] == "-" {
                    exponent.append(chars[probe]); probe += 1
                }
                var sawExponentDigit = false
                while probe < chars.count, chars[probe].isNumber {
                    exponent.append(chars[probe]); probe += 1; sawExponentDigit = true
                }
                if sawExponentDigit {
                    text += exponent
                    index = probe
                }
            }
            guard !text.isEmpty, text != "-", text != "+", text != "." else { return nil }
            return Double(text).map { CGFloat($0) }
        }
        
        func readFlag() -> CGFloat? {
            skipSeparators()
            guard index < chars.count, chars[index] == "0" || chars[index] == "1" else { return nil }
            defer { index += 1 }
            return chars[index] == "1" ? 1 : 0
        }
        
        while true {
            skipSeparators()
            guard index < chars.count else { break }
            
            var command: Character
            if "MmLlHhVvCcSsQqTtAaZz".contains(chars[index]) {
                command = chars[index]
                index += 1
            } else if "MmLlHhVvCcSsQqTtAa".contains(lastCommand) {
                // Implicit repetition of the previous command; a repeated "M"/"m"
                // behaves as "L"/"l" per the SVG path spec.
                command = lastCommand == "M" ? "L" : (lastCommand == "m" ? "l" : lastCommand)
            } else {
                break
            }
            
            switch command {
            case "M", "m":
                guard let x = readNumber(), let y = readNumber() else { return finalize(path) }
                current = command == "m" ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.move(to: current)
                start = current
                lastCubicControl = nil; lastQuadControl = nil
                
            case "L", "l":
                guard let x = readNumber(), let y = readNumber() else { return finalize(path) }
                current = command == "l" ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil
                
            case "H", "h":
                guard let x = readNumber() else { return finalize(path) }
                current.x = command == "h" ? current.x + x : x
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil
                
            case "V", "v":
                guard let y = readNumber() else { return finalize(path) }
                current.y = command == "v" ? current.y + y : y
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil
                
            case "C", "c":
                guard let x1 = readNumber(), let y1 = readNumber(),
                      let x2 = readNumber(), let y2 = readNumber(),
                      let x = readNumber(), let y = readNumber() else { return finalize(path) }
                let offset = command == "c" ? current : .zero
                let c1 = CGPoint(x: x1 + offset.x, y: y1 + offset.y)
                let c2 = CGPoint(x: x2 + offset.x, y: y2 + offset.y)
                let end = CGPoint(x: x + offset.x, y: y + offset.y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastCubicControl = c2; lastQuadControl = nil
                current = end
                
            case "S", "s":
                guard let x2 = readNumber(), let y2 = readNumber(),
                      let x = readNumber(), let y = readNumber() else { return finalize(path) }
                let offset = command == "s" ? current : .zero
                let c2 = CGPoint(x: x2 + offset.x, y: y2 + offset.y)
                let end = CGPoint(x: x + offset.x, y: y + offset.y)
                let c1 = lastCubicControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addCurve(to: end, control1: c1, control2: c2)
                lastCubicControl = c2; lastQuadControl = nil
                current = end
                
            case "Q", "q":
                guard let x1 = readNumber(), let y1 = readNumber(),
                      let x = readNumber(), let y = readNumber() else { return finalize(path) }
                let offset = command == "q" ? current : .zero
                let c = CGPoint(x: x1 + offset.x, y: y1 + offset.y)
                let end = CGPoint(x: x + offset.x, y: y + offset.y)
                path.addQuadCurve(to: end, control: c)
                lastQuadControl = c; lastCubicControl = nil
                current = end
                
            case "T", "t":
                guard let x = readNumber(), let y = readNumber() else { return finalize(path) }
                let offset = command == "t" ? current : .zero
                let end = CGPoint(x: x + offset.x, y: y + offset.y)
                let c = lastQuadControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addQuadCurve(to: end, control: c)
                lastQuadControl = c; lastCubicControl = nil
                current = end
                
            case "A", "a":
                guard let rx = readNumber(), let ry = readNumber(), let xRotation = readNumber(),
                      let largeArc = readFlag(), let sweep = readFlag(),
                      let x = readNumber(), let y = readNumber() else { return finalize(path) }
                let offset = command == "a" ? current : .zero
                let end = CGPoint(x: x + offset.x, y: y + offset.y)
                appendArc(to: path, from: current, to: end, rx: rx, ry: ry,
                          xAxisRotationDegrees: xRotation, largeArcFlag: largeArc != 0, sweepFlag: sweep != 0)
                current = end
                lastCubicControl = nil; lastQuadControl = nil
                
            case "Z", "z":
                path.closeSubpath()
                current = start
                lastCubicControl = nil; lastQuadControl = nil
                
            default:
                return finalize(path)
            }
            
            lastCommand = command
        }
        
        return finalize(path)
    }
    
    /// The parsed path, or nil if it's empty.
    private static func finalize(_ path: CGMutablePath) -> CGPath? {
        path.isEmpty ? nil : path
    }
    
    /// Standard SVG elliptical-arc-to-bezier conversion (endpoint-to-center
    /// parameterization, per the SVG 1.1 spec appendix F.6).
    private static func appendArc(
        to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint,
        rx: CGFloat, ry: CGFloat, xAxisRotationDegrees: CGFloat,
        largeArcFlag: Bool, sweepFlag: Bool
    ) {
        if rx == 0 || ry == 0 || p0 == p1 {
            path.addLine(to: p1)
            return
        }
        var rx = abs(rx), ry = abs(ry)
        let phi = xAxisRotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        
        let dx2 = (p0.x - p1.x) / 2
        let dy2 = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2
        
        var lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale; ry *= scale
            lambda = 1
        }
        
        let sign: CGFloat = (largeArcFlag != sweepFlag) ? 1 : -1
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coef = den == 0 ? 0 : sign * sqrt(max(0, num / den))
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * (-ry * x1p / rx)
        
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
        
        func vectorAngle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var angle = acos(max(-1, min(1, len == 0 ? 1 : dot / len)))
            if (ux * vy - uy * vx) < 0 { angle = -angle }
            return angle
        }
        
        let theta1 = vectorAngle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var deltaTheta = vectorAngle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweepFlag, deltaTheta > 0 { deltaTheta -= 2 * .pi }
        if sweepFlag, deltaTheta < 0 { deltaTheta += 2 * .pi }
        
        let segmentCount = max(1, Int(ceil(abs(deltaTheta) / (.pi / 2))))
        let delta = deltaTheta / CGFloat(segmentCount)
        var theta = theta1
        
        for _ in 0..<segmentCount {
            let nextTheta = theta + delta
            let t = 4.0 / 3.0 * tan(delta / 4)
            
            let start = CGPoint(
                x: cx + cosPhi * rx * cos(theta) - sinPhi * ry * sin(theta),
                y: cy + sinPhi * rx * cos(theta) + cosPhi * ry * sin(theta)
            )
            let end = CGPoint(
                x: cx + cosPhi * rx * cos(nextTheta) - sinPhi * ry * sin(nextTheta),
                y: cy + sinPhi * rx * cos(nextTheta) + cosPhi * ry * sin(nextTheta)
            )
            let startTangent = CGPoint(
                x: -rx * cosPhi * sin(theta) - ry * sinPhi * cos(theta),
                y: -rx * sinPhi * sin(theta) + ry * cosPhi * cos(theta)
            )
            let endTangent = CGPoint(
                x: -rx * cosPhi * sin(nextTheta) - ry * sinPhi * cos(nextTheta),
                y: -rx * sinPhi * sin(nextTheta) + ry * cosPhi * cos(nextTheta)
            )
            
            let control1 = CGPoint(x: start.x + t * startTangent.x, y: start.y + t * startTangent.y)
            let control2 = CGPoint(x: end.x - t * endTangent.x, y: end.y - t * endTangent.y)
            path.addCurve(to: end, control1: control1, control2: control2)
            
            theta = nextTheta
        }
    }
}
