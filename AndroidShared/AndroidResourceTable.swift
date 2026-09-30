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
    
    private enum TypeFlag {
        static let sparse: UInt8 = 0x01
        static let offset16: UInt8 = 0x02
    }
    
    private enum EntryFlag {
        static let complex: UInt16 = 0x0001
        static let compact: UInt16 = 0x0008
    }
    
    private let bytes: [UInt8]
    private var valueStringPool: [String] = []
    private var packages: [Package] = []
    
    /// Parses a resources.arsc file; nil if it isn't a resource table.
    init?(data: Data) {
        self.bytes = [UInt8](data)
        guard parse() else { return nil }
    }
    
    // MARK: - Byte-level reading (mirrors AXMLParser's helpers)
    
    /// Little-endian UInt16 at `offset`, or 0 when out of bounds.
    private func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
    
    /// Little-endian UInt32 at `offset`, or 0 when out of bounds.
    private func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
    }
    
    /// Reads a string-pool UTF-8 length (1 or 2 bytes) and advances `pos` past it.
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
    
    /// Reads a string-pool UTF-16 length (1 or 2 units) and advances `pos` past it.
    private func decodeUTF16Length(_ pos: inout Int) -> Int {
        let first = Int(u16(pos)); pos += 2
        if first & 0x8000 != 0 {
            let second = Int(u16(pos)); pos += 2
            return ((first & 0x7FFF) << 16) | second
        }
        return first
    }
    
    /// Decodes every string of the `ResStringPool` chunk at `chunkStart` (UTF-8 or UTF-16).
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
    
    /// Reads the global value string pool and each package chunk.
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
    
    /// Reads a package's type/key string pools and indexes its type chunks (one per config).
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
        resolveAll(resID, preferredDensity: preferredDensity).first
    }
    
    /// Resolves a resource ID to its value in every config that defines it, ordered
    /// by how close each config's density is to `preferredDensity` (ties keep table order).
    func resolveAll(_ resID: UInt32, preferredDensity: Int = 480) -> [AXMLValue] {
        let packageID = UInt8((resID >> 24) & 0xFF)
        let typeIndex = Int((resID >> 16) & 0xFF) - 1
        let entryIndex = Int(resID & 0xFFFF)
        guard let package = packages.first(where: { $0.id == packageID }),
              let chunks = package.types[typeIndex], !chunks.isEmpty else { return [] }
        
        let ordered = chunks.enumerated().sorted {
            let lhs = abs($0.element.density - preferredDensity)
            let rhs = abs($1.element.density - preferredDensity)
            return lhs != rhs ? lhs < rhs : $0.offset < $1.offset
        }
        return ordered.compactMap { readEntry(chunk: $0.element, entryIndex: entryIndex) }
    }
    
    /// Convenience for the common case of resolving a reference straight to a string
    /// (e.g. an in-APK resource path, or a literal label string).
    /// Follows alias chains such as `@string/app_name` -> `@string/app_name_release`.
    func resolveToString(_ resID: UInt32, preferredDensity: Int = 480) -> String? {
        var value = resolve(resID, preferredDensity: preferredDensity)
        for _ in 0..<8 {
            switch value {
            case .string(let s)?:
                return s
            case .reference(let next)?:
                value = resolve(next, preferredDensity: preferredDensity)
            default:
                return nil
            }
        }
        return nil
    }
    
    /// The simple value of an entry in one config (classic or compact encoding); nil if the
    /// config doesn't define it or it's a complex (map/style) entry.
    private func readEntry(chunk: TypeChunk, entryIndex: Int) -> AXMLValue? {
        guard let entryOffset = entryOffset(chunk: chunk, entryIndex: entryIndex) else { return nil }
        let entryStart = chunk.chunkStart + chunk.entriesStart + entryOffset
        guard entryStart + 8 <= bytes.count else { return nil }
        let entryFlags = u16(entryStart + 2)
        if entryFlags & EntryFlag.compact != 0 {
            // Compact entry: { u16 key, u16 flags (data type in the high byte), u32 data }.
            return decodeGlobalValue(dataType: UInt8(entryFlags >> 8), data: u32(entryStart + 4))
        }
        guard entryFlags & EntryFlag.complex == 0 else { return nil } // map/style entries unsupported
        let valueStart = entryStart + Int(u16(entryStart))
        guard valueStart + 8 <= bytes.count else { return nil }
        let dataType = bytes[valueStart + 3]
        let dataValue = u32(valueStart + 4)
        return decodeGlobalValue(dataType: dataType, data: dataValue)
    }
    
    /// Looks up an entry's offset (relative to the chunk's entries start) in the
    /// chunk's offset table, or nil if this config doesn't define the entry.
    private func entryOffset(chunk: TypeChunk, entryIndex: Int) -> Int? {
        let tableStart = chunk.chunkStart + chunk.headerSize
        if chunk.flags & TypeFlag.sparse != 0 {
            // Sorted { u16 entry index, u16 offset / 4 } pairs; binary search them.
            var low = 0, high = chunk.entryCount - 1
            while low <= high {
                let mid = (low + high) / 2
                let index = Int(u16(tableStart + mid * 4))
                if index == entryIndex { return Int(u16(tableStart + mid * 4 + 2)) * 4 }
                if index < entryIndex { low = mid + 1 } else { high = mid - 1 }
            }
            return nil
        }
        guard entryIndex < chunk.entryCount else { return nil }
        if chunk.flags & TypeFlag.offset16 != 0 {
            let raw = u16(tableStart + entryIndex * 2)
            return raw == 0xFFFF ? nil : Int(raw) * 4
        }
        let raw = u32(tableStart + entryIndex * 4)
        return raw == 0xFFFF_FFFF ? nil : Int(raw)
    }
    
    /// Converts a typed `Res_value`, resolving string indices against the global pool.
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
