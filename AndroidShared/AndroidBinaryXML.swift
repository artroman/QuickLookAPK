//
//  AndroidBinaryXML.swift
//  QuickLookAPKPreview
//
//  Minimal reader for Android's compiled binary XML ("AXML") chunk format,
//  as used by both AndroidManifest.xml and compiled vector-drawable resources
//  inside an APK. Format reference: androidfw/ResourceTypes.h (AOSP).
//

import Foundation

enum AXMLValue {
    case string(String)
    case reference(UInt32)
    case intValue(Int32)
    case boolValue(Bool)
    case other(type: UInt8, data: UInt32)
}

struct AXMLAttribute {
    let resourceID: UInt32?
    let name: String
    let value: AXMLValue
}

final class AXMLElement {
    let name: String
    let attributes: [AXMLAttribute]
    var children: [AXMLElement] = []
    
    init(name: String, attributes: [AXMLAttribute]) {
        self.name = name
        self.attributes = attributes
    }
    
    func attribute(id: UInt32) -> AXMLAttribute? {
        attributes.first { $0.resourceID == id }
    }
    
    func attribute(named name: String) -> AXMLAttribute? {
        attributes.first { $0.name == name }
    }
    
    func firstChild(named name: String) -> AXMLElement? {
        children.first { $0.name == name }
    }
}

struct AXMLDocument {
    let root: AXMLElement?
}

/// Parses the AXML chunk format shared by AndroidManifest.xml and compiled
/// vector-drawable XML resources.
final class AXMLParser {
    private enum ChunkType {
        static let stringPool: UInt16 = 0x0001
        static let xmlStartElement: UInt16 = 0x0102
        static let xmlEndElement: UInt16 = 0x0103
        static let xmlResourceMap: UInt16 = 0x0180
    }
    
    private enum ValueType: UInt8 {
        case reference = 0x01
        case string = 0x03
        case intDec = 0x10
        case intHex = 0x11
        case intBoolean = 0x12
    }
    
    private let bytes: [UInt8]
    private var stringPool: [String] = []
    private var resourceMap: [UInt32] = []
    
    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }
    
    static func parse(data: Data) -> AXMLDocument? {
        AXMLParser(bytes: [UInt8](data)).parseDocument()
    }
    
    // MARK: - Byte-level reading
    
    private func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
    
    private func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
    }
    
    private func i32(_ offset: Int) -> Int32 {
        Int32(bitPattern: u32(offset))
    }
    
    private func stringAt(_ index: Int32) -> String? {
        guard index >= 0, Int(index) < stringPool.count else { return nil }
        return stringPool[Int(index)]
    }
    
    // MARK: - String pool
    
    private func decodeUTF8Length(_ pos: inout Int) -> Int {
        guard pos < bytes.count else { return 0 }
        let first = Int(bytes[pos]); pos += 1
        if first & 0x80 != 0 {
            guard pos < bytes.count else { return 0 }
            let second = Int(bytes[pos]); pos += 1
            return ((first & 0x7F) << 8) | second
        }
        return first
    }
    
    private func decodeUTF16Length(_ pos: inout Int) -> Int {
        let first = Int(u16(pos)); pos += 2
        if first & 0x8000 != 0 {
            let second = Int(u16(pos)); pos += 2
            return ((first & 0x7FFF) << 16) | second
        }
        return first
    }
    
    private func parseStringPool(at chunkStart: Int) -> [String] {
        let headerSize = Int(u16(chunkStart + 2))
        let stringCount = Int(u32(chunkStart + 8))
        let flags = u32(chunkStart + 16)
        let stringsStart = Int(u32(chunkStart + 20))
        let isUTF8 = (flags & 0x100) != 0
        
        var result: [String] = []
        result.reserveCapacity(stringCount)
        
        let indexBase = chunkStart + headerSize
        for i in 0..<stringCount {
            let entryOffset = Int(u32(indexBase + i * 4))
            let strStart = chunkStart + stringsStart + entryOffset
            guard strStart >= 0, strStart < bytes.count else {
                result.append("")
                continue
            }
            
            if isUTF8 {
                var pos = strStart
                _ = decodeUTF8Length(&pos) // UTF-16 (character) length, unused
                let byteLen = decodeUTF8Length(&pos)
                guard byteLen >= 0, pos + byteLen <= bytes.count else {
                    result.append("")
                    continue
                }
                result.append(String(decoding: bytes[pos..<pos + byteLen], as: UTF8.self))
            } else {
                var pos = strStart
                let charLen = decodeUTF16Length(&pos)
                var units: [UInt16] = []
                units.reserveCapacity(charLen)
                for _ in 0..<charLen where pos + 2 <= bytes.count {
                    units.append(u16(pos))
                    pos += 2
                }
                result.append(String(decoding: units, as: UTF16.self))
            }
        }
        return result
    }
    
    // MARK: - Values
    
    private func decodeValue(dataType: UInt8, data: UInt32) -> AXMLValue {
        switch ValueType(rawValue: dataType) {
        case .string:
            return .string(stringAt(Int32(bitPattern: data)) ?? "")
        case .reference:
            return .reference(data)
        case .intBoolean:
            return .boolValue(data != 0)
        case .intDec, .intHex:
            return .intValue(Int32(bitPattern: data))
        case .none:
            return .other(type: dataType, data: data)
        }
    }
    
    // MARK: - Document walk
    
    private func parseDocument() -> AXMLDocument? {
        guard bytes.count >= 8 else { return nil }
        let topHeaderSize = Int(u16(2))
        let topChunkSize = Int(u32(4))
        guard topHeaderSize > 0, topChunkSize <= bytes.count else { return nil }
        
        var stack: [AXMLElement] = []
        var root: AXMLElement?
        
        var pos = topHeaderSize
        while pos + 8 <= topChunkSize && pos + 8 <= bytes.count {
            let chunkType = u16(pos)
            let chunkHeaderSize = Int(u16(pos + 2))
            let chunkSize = Int(u32(pos + 4))
            guard chunkSize >= 8, pos + chunkSize <= bytes.count else { break }
            
            switch chunkType {
            case ChunkType.stringPool:
                stringPool = parseStringPool(at: pos)
                
            case ChunkType.xmlResourceMap:
                let mapStart = pos + chunkHeaderSize
                let count = (chunkSize - chunkHeaderSize) / 4
                resourceMap = (0..<count).map { u32(mapStart + $0 * 4) }
                
            case ChunkType.xmlStartElement:
                // ResXMLTree_node (16 bytes) then ResXMLTree_attrExt.
                let extStart = pos + 16
                let nameRef = i32(extStart + 4)
                let attributeStart = Int(u16(extStart + 8))
                let attributeSize = Int(u16(extStart + 10))
                let attributeCount = Int(u16(extStart + 12))
                
                var attrs: [AXMLAttribute] = []
                attrs.reserveCapacity(attributeCount)
                let attrsBase = extStart + attributeStart
                for a in 0..<attributeCount {
                    let attrOffset = attrsBase + a * attributeSize
                    guard attrOffset + 20 <= bytes.count else { break }
                    let attrNameRef = i32(attrOffset + 4)
                    let dataType = bytes[attrOffset + 12 + 3]
                    let dataValue = u32(attrOffset + 12 + 4)
                    
                    let resID: UInt32? = attrNameRef >= 0 && Int(attrNameRef) < resourceMap.count
                    ? resourceMap[Int(attrNameRef)]
                    : nil
                    let attrName = stringAt(attrNameRef) ?? ""
                    let value = decodeValue(dataType: dataType, data: dataValue)
                    attrs.append(AXMLAttribute(resourceID: resID, name: attrName, value: value))
                }
                
                let element = AXMLElement(name: stringAt(nameRef) ?? "", attributes: attrs)
                if let parent = stack.last {
                    parent.children.append(element)
                } else if root == nil {
                    root = element
                }
                stack.append(element)
                
            case ChunkType.xmlEndElement:
                if !stack.isEmpty { stack.removeLast() }
                
            default:
                break
            }
            
            pos += chunkSize
        }
        
        return AXMLDocument(root: root)
    }
}
