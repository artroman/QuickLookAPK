//
//  AndroidResourceTable.swift
//  QuickLookAPKPreview
//
//  Minimal reader for an APK's resources.arsc resource table, used to resolve
//  resource-reference values (e.g. an <application android:icon="@mipmap/..."/>
//  attribute) found while parsing AndroidManifest.xml's binary XML.
//  Format reference: androidfw/ResourceTypes.h (AOSP).
//

import Foundation

final class AndroidResourceTable {
    private struct TypeChunk {
        let density: Int
        let entryCount: Int
        let entriesStart: Int
        let chunkStart: Int
        let headerSize: Int
        let flags: UInt8
    }

    private struct Package {
        let id: UInt8
        let typeStrings: [String]
        let keyStrings: [String]
        let types: [Int: [TypeChunk]] // 0-based type index -> one chunk per config
    }

    private enum ChunkType {
        static let stringPool: UInt16 = 0x0001
        static let table: UInt16 = 0x0002
        static let tablePackage: UInt16 = 0x0200
        static let tableType: UInt16 = 0x0201
    }

    private let bytes: [UInt8]
    private var valueStringPool: [String] = []
    private var packages: [Package] = []

    init?(data: Data) {
        self.bytes = [UInt8](data)
        guard parse() else { return nil }
    }

    // MARK: - Byte-level reading (mirrors AXMLParser's helpers)

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
                _ = decodeUTF8Length(&pos)
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

    // MARK: - Parsing

    private func parse() -> Bool {
        guard bytes.count >= 12, u16(0) == ChunkType.table else { return false }
        let topHeaderSize = Int(u16(2))
        let topChunkSize = Int(u32(4))
        guard topHeaderSize > 0, topChunkSize <= bytes.count else { return false }

        var pos = topHeaderSize
        while pos + 8 <= topChunkSize && pos + 8 <= bytes.count {
            let chunkType = u16(pos)
            let chunkSize = Int(u32(pos + 4))
            guard chunkSize >= 8, pos + chunkSize <= bytes.count else { break }

            switch chunkType {
            case ChunkType.stringPool:
                valueStringPool = parseStringPool(at: pos)
            case ChunkType.tablePackage:
                if let pkg = parsePackage(chunkStart: pos, chunkSize: chunkSize) {
                    packages.append(pkg)
                }
            default:
                break
            }
            pos += chunkSize
        }
        return true
    }

    private func parsePackage(chunkStart: Int, chunkSize: Int) -> Package? {
        guard chunkStart + 288 <= bytes.count else { return nil }
        let id = UInt8(u32(chunkStart + 8) & 0xFF)
        let typeStringsOffset = Int(u32(chunkStart + 268))
        let keyStringsOffset = Int(u32(chunkStart + 276))
        let headerSize = Int(u16(chunkStart + 2))

        var typeStrings: [String] = []
        var keyStrings: [String] = []
        var types: [Int: [TypeChunk]] = [:]

        var pos = chunkStart + headerSize
        let end = chunkStart + chunkSize
        while pos + 8 <= end && pos + 8 <= bytes.count {
            let innerType = u16(pos)
            let innerHeaderSize = Int(u16(pos + 2))
            let innerSize = Int(u32(pos + 4))
            guard innerSize >= 8, pos + innerSize <= bytes.count else { break }

            let relOffset = pos - chunkStart
            switch innerType {
            case ChunkType.stringPool:
                let pool = parseStringPool(at: pos)
                if relOffset == typeStringsOffset {
                    typeStrings = pool
                } else if relOffset == keyStringsOffset {
                    keyStrings = pool
                }
            case ChunkType.tableType:
                guard pos + 20 <= bytes.count else { break }
                let typeID = Int(bytes[pos + 8]) // 1-based
                let flags = bytes[pos + 9]
                let entryCount = Int(u32(pos + 12))
                let entriesStart = Int(u32(pos + 16))
                let density = Int(u16(pos + 0x14 + 14))
                let chunk = TypeChunk(density: density, entryCount: entryCount, entriesStart: entriesStart, chunkStart: pos, headerSize: innerHeaderSize, flags: flags)
                types[typeID - 1, default: []].append(chunk)
            default:
                break
            }
            pos += innerSize
        }

        return Package(id: id, typeStrings: typeStrings, keyStrings: keyStrings, types: types)
    }

    // MARK: - Resolution

    /// Resolves a resource ID (as found in a `TYPE_REFERENCE` value) to its value,
    /// preferring the config whose density is closest to `preferredDensity`.
    func resolve(_ resID: UInt32, preferredDensity: Int = 480) -> AXMLValue? {
        let packageID = UInt8((resID >> 24) & 0xFF)
        let typeIndex = Int((resID >> 16) & 0xFF) - 1
        let entryIndex = Int(resID & 0xFFFF)
        guard let package = packages.first(where: { $0.id == packageID }),
              let chunks = package.types[typeIndex], !chunks.isEmpty else { return nil }

        let ordered = chunks.sorted {
            abs($0.density - preferredDensity) < abs($1.density - preferredDensity)
        }
        for chunk in ordered {
            if let value = readEntry(chunk: chunk, entryIndex: entryIndex) {
                return value
            }
        }
        return nil
    }

    /// Convenience for the common case of resolving a reference straight to a string
    /// (e.g. an in-APK resource path, or a literal label string).
    func resolveToString(_ resID: UInt32, preferredDensity: Int = 480) -> String? {
        guard case .string(let s)? = resolve(resID, preferredDensity: preferredDensity) else { return nil }
        return s
    }

    private func readEntry(chunk: TypeChunk, entryIndex: Int) -> AXMLValue? {
        guard entryIndex < chunk.entryCount, chunk.flags & 0x01 == 0 else { return nil } // FLAG_SPARSE unsupported
        let offsetTableStart = chunk.chunkStart + chunk.headerSize
        let entryOffsetRaw = u32(offsetTableStart + entryIndex * 4)
        guard entryOffsetRaw != 0xFFFFFFFF else { return nil } // no entry for this config
        let entryStart = chunk.chunkStart + chunk.entriesStart + Int(entryOffsetRaw)
        guard entryStart + 8 <= bytes.count else { return nil }
        let entrySize = Int(u16(entryStart))
        let entryFlags = u16(entryStart + 2)
        guard entryFlags & 0x0001 == 0 else { return nil } // complex (map/style) entries unsupported
        let valueStart = entryStart + entrySize
        guard valueStart + 8 <= bytes.count else { return nil }
        let dataType = bytes[valueStart + 3]
        let dataValue = u32(valueStart + 4)
        return decodeGlobalValue(dataType: dataType, data: dataValue)
    }

    private func decodeGlobalValue(dataType: UInt8, data: UInt32) -> AXMLValue {
        switch dataType {
        case 0x03:
            return .string(Int(data) < valueStringPool.count ? valueStringPool[Int(data)] : "")
        case 0x01:
            return .reference(data)
        case 0x12:
            return .boolValue(data != 0)
        case 0x10, 0x11:
            return .intValue(Int32(bitPattern: data))
        default:
            return .other(type: dataType, data: data)
        }
    }
}
