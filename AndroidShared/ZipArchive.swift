//
//  ZipArchive.swift
//  QuickLookAPKPreview
//
//  Minimal in-process ZIP reader (an APK is a ZIP file). Deliberately avoids
//  shelling out to /usr/bin/unzip or any other subprocess: App Sandbox blocks
//  a Quick Look extension from executing a bundled third-party binary (that's
//  what broke the old aapt-based implementation), and there was no reason to
//  trust that invoking a system binary via NSTask would necessarily be exempt
//  either. Using Apple's Compression framework in-process sidesteps the
//  question entirely.
//

import Compression
import Foundation

struct ZipEntry {
    let name: String
    let compressionMethod: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
}

final class ZipArchive {
    private let bytes: [UInt8]
    private(set) var entries: [String: ZipEntry] = [:]
    private(set) var entryNames: [String] = []

    init?(path: String) {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        self.bytes = [UInt8](data)
        guard parseCentralDirectory() else { return nil }
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

    // MARK: - Central directory

    private func parseCentralDirectory() -> Bool {
        let eocdSignature: UInt32 = 0x0605_4b50
        let minEOCDSize = 22
        guard bytes.count >= minEOCDSize else { return false }

        // The EOCD record sits at the end of the file, optionally followed by a
        // comment (up to 65535 bytes); scan backwards for its signature.
        let searchFloor = max(0, bytes.count - minEOCDSize - 65536)
        var eocdOffset = -1
        var i = bytes.count - minEOCDSize
        while i >= searchFloor {
            if u32(i) == eocdSignature {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard eocdOffset >= 0 else { return false }

        let centralDirectoryEntryCount = Int(u16(eocdOffset + 10))
        let centralDirectorySize = Int(u32(eocdOffset + 12))
        let centralDirectoryOffset = Int(u32(eocdOffset + 16))
        guard centralDirectoryOffset >= 0, centralDirectoryOffset + centralDirectorySize <= bytes.count else {
            return false
        }

        let centralHeaderSignature: UInt32 = 0x0201_4b50
        var pos = centralDirectoryOffset
        var parsed = 0
        while parsed < centralDirectoryEntryCount, pos + 46 <= bytes.count {
            guard u32(pos) == centralHeaderSignature else { break }

            let compressionMethod = u16(pos + 10)
            let compressedSize = Int(u32(pos + 20))
            let uncompressedSize = Int(u32(pos + 24))
            let nameLength = Int(u16(pos + 28))
            let extraLength = Int(u16(pos + 30))
            let commentLength = Int(u16(pos + 32))
            let localHeaderOffset = Int(u32(pos + 42))

            let nameStart = pos + 46
            guard nameStart + nameLength <= bytes.count else { break }
            let name = String(decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self)

            let entry = ZipEntry(
                name: name,
                compressionMethod: compressionMethod,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            )
            entries[name] = entry
            entryNames.append(name)

            pos = nameStart + nameLength + extraLength + commentLength
            parsed += 1
        }
        return true
    }

    // MARK: - Entry extraction

    func data(for entryName: String) -> Data? {
        guard let entry = entries[entryName] else { return nil }

        let localHeaderSignature: UInt32 = 0x0403_4b50
        let localPos = entry.localHeaderOffset
        guard u32(localPos) == localHeaderSignature else { return nil }

        let nameLength = Int(u16(localPos + 26))
        let extraLength = Int(u16(localPos + 28))
        let dataStart = localPos + 30 + nameLength + extraLength
        guard dataStart >= 0, dataStart + entry.compressedSize <= bytes.count else { return nil }

        let compressed = Array(bytes[dataStart..<dataStart + entry.compressedSize])
        switch entry.compressionMethod {
        case 0: // stored (no compression)
            return Data(compressed)
        case 8: // deflate
            return inflate(compressed, expectedSize: entry.uncompressedSize)
        default:
            return nil
        }
    }

    /// ZIP's "deflate" entries are raw DEFLATE streams (no zlib/gzip framing).
    /// Apple's `Compression` framework's `COMPRESSION_ZLIB` algorithm operates on
    /// exactly that raw format despite the name.
    private func inflate(_ input: [UInt8], expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var output = [UInt8](repeating: 0, count: expectedSize)
        let decodedCount = output.withUnsafeMutableBytes { outPtr -> Int in
            input.withUnsafeBytes { inPtr -> Int in
                compression_decode_buffer(
                    outPtr.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    inPtr.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard decodedCount == expectedSize else { return nil }
        return Data(output)
    }
}
