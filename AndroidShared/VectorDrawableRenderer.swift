//
//  VectorDrawableRenderer.swift
//  QuickLookAPKPreview
//
//  Rasterizes a compiled Android VectorDrawable XML resource (the same AXML
//  binary chunk format as AndroidManifest.xml) into a PNG, so adaptive-icon /
//  vector-drawable app icons can be shown instead of a blank icon.
//

import AppKit
import CoreGraphics
import Foundation

enum VectorDrawableRenderer {
    /// Renders a compiled vector-drawable resource's bytes into PNG data.
    /// `targetSize` is the longer edge of the output bitmap, in pixels.
    static func render(data: Data, targetSize: CGFloat = 512) -> Data? {
        guard let document = AXMLParser.parse(data: data),
              let root = document.root,
              root.name == "vector" else {
            return nil
        }

        let viewportWidth = floatAttribute(root, "viewportWidth") ?? 24
        let viewportHeight = floatAttribute(root, "viewportHeight") ?? 24
        guard viewportWidth > 0, viewportHeight > 0 else { return nil }

        var paths: [(path: CGPath, color: CGColor, alpha: CGFloat)] = []
        collectPaths(root, into: &paths)
        guard !paths.isEmpty else { return nil }

        let aspect = viewportWidth / viewportHeight
        let pixelWidth = max(1, Int((aspect >= 1 ? targetSize : targetSize * aspect).rounded()))
        let pixelHeight = max(1, Int((aspect >= 1 ? targetSize / aspect : targetSize).rounded()))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        // Flip to a top-left-origin, Y-down coordinate space matching the vector
        // drawable's own coordinate system, while also scaling viewport units to pixels.
        let scaleX = CGFloat(pixelWidth) / viewportWidth
        let scaleY = CGFloat(pixelHeight) / viewportHeight
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scaleX, y: -scaleY)

        for (path, color, alpha) in paths {
            context.setAlpha(alpha)
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath()
        }

        guard let cgImage = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - AXML element inspection

    private static func floatAttribute(_ element: AXMLElement, _ name: String) -> CGFloat? {
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

    private static func collectPaths(_ element: AXMLElement, into paths: inout [(path: CGPath, color: CGColor, alpha: CGFloat)]) {
        if element.name == "path", let pathDataAttr = element.attribute(named: "pathData") {
            if case .string(let pathData) = pathDataAttr.value, let cgPath = SVGPathParser.parse(pathData) {
                let color = colorAttribute(element, "fillColor") ?? CGColor(red: 0, green: 0, blue: 0, alpha: 1)
                let alpha = floatAttribute(element, "fillAlpha") ?? 1
                paths.append((cgPath, color, alpha))
            }
        }
        // Groups (and any other container elements) are walked transparently;
        // group transforms (rotate/scale/translate/pivot) are not applied (out of
        // scope for v1) — most launcher icons don't rely on them for the base shape.
        for child in element.children {
            collectPaths(child, into: &paths)
        }
    }

    private static func colorAttribute(_ element: AXMLElement, _ name: String) -> CGColor? {
        guard let attr = element.attribute(named: name) else { return nil }
        switch attr.value {
        case .other(let type, let data):
            switch type {
            case 0x1c: // TYPE_INT_COLOR_ARGB8
                return colorFromARGB8(data)
            case 0x1d: // TYPE_INT_COLOR_RGB8
                return colorFromARGB8(0xFF00_0000 | data)
            case 0x1e: // TYPE_INT_COLOR_ARGB4
                return colorFromARGB8(expandShortColor(data, hasAlpha: true))
            case 0x1f: // TYPE_INT_COLOR_RGB4
                return colorFromARGB8(expandShortColor(data, hasAlpha: false))
            default:
                return nil
            }
        case .string(let s):
            return colorFromHexString(s)
        default:
            return nil // TYPE_REFERENCE (theme/color resource) intentionally unsupported in v1
        }
    }

    private static func colorFromARGB8(_ value: UInt32) -> CGColor {
        let a = CGFloat((value >> 24) & 0xFF) / 255
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return CGColor(red: r, green: g, blue: b, alpha: a)
    }

    private static func expandShortColor(_ value: UInt32, hasAlpha: Bool) -> UInt32 {
        func expand(_ nibble: UInt32) -> UInt32 { (nibble << 4) | nibble }
        let a: UInt32 = hasAlpha ? (value >> 12) & 0xF : 0xF
        let r: UInt32 = (value >> 8) & 0xF
        let g: UInt32 = (value >> 4) & 0xF
        let b: UInt32 = value & 0xF
        return (expand(a) << 24) | (expand(r) << 16) | (expand(g) << 8) | expand(b)
    }

    private static func colorFromHexString(_ string: String) -> CGColor? {
        var hex = string
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard let value = UInt32(hex, radix: 16) else { return nil }
        switch hex.count {
        case 6: return colorFromARGB8(0xFF00_0000 | value)
        case 8: return colorFromARGB8(value)
        default: return nil
        }
    }
}

/// Parses the SVG-compatible path-data mini-language used by VectorDrawable's
/// `android:pathData` attribute into a `CGPath`.
enum SVGPathParser {
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
