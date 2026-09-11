import Foundation

/// Reads the newest value of one key straight from LevelDB table and log files.
/// Electron keeps the database lock while it runs, so the files are parsed
/// read-only instead of opening the database.
enum LevelDBSnapshotReader {
    private static let tableMagic: UInt64 = 0xDB47_7524_8B80_FB57
    private static let logBlockSize = 32768
    private static let maximumFileBytes = 64 * 1024 * 1024

    private struct LatestEntry {
        private var sequence: UInt64?
        private(set) var value: [UInt8]?

        mutating func offer(sequence: UInt64, value: ArraySlice<UInt8>?) {
            if let current = self.sequence, current >= sequence {
                return
            }
            self.sequence = sequence
            self.value = value.map { Array($0) }
        }
    }

    static func latestValue(forKey key: [UInt8], in directory: URL) -> [UInt8]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        var latest = LatestEntry()
        for name in names {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            switch url.pathExtension {
            case "ldb", "sst":
                guard let bytes = self.readFile(url) else { continue }
                self.scanTable(bytes, key: key, latest: &latest)
            case "log":
                guard let bytes = self.readFile(url) else { continue }
                self.scanLog(bytes, key: key, latest: &latest)
            default:
                continue
            }
        }
        return latest.value
    }

    static func snappyDecompress(_ input: [UInt8]) -> [UInt8]? {
        var cursor = 0
        guard let expectedLength = self.varint(input, &cursor, limit: input.count),
              expectedLength <= self.maximumFileBytes
        else {
            return nil
        }
        var output: [UInt8] = []
        output.reserveCapacity(expectedLength)
        while cursor < input.count {
            let tag = input[cursor]
            cursor += 1
            let length: Int
            let distance: Int
            switch tag & 0x03 {
            case 0:
                var literalLength = Int(tag >> 2)
                if literalLength >= 60 {
                    let width = literalLength - 59
                    guard width <= input.count - cursor else { return nil }
                    literalLength = Int(self.littleEndian(input, at: cursor, width: width))
                    cursor += width
                }
                literalLength += 1
                guard literalLength <= input.count - cursor,
                      literalLength <= expectedLength - output.count
                else {
                    return nil
                }
                output.append(contentsOf: input[cursor ..< cursor + literalLength])
                cursor += literalLength
                continue
            case 1:
                guard cursor < input.count else { return nil }
                length = Int((tag >> 2) & 0x07) + 4
                distance = Int(tag >> 5) << 8 | Int(input[cursor])
                cursor += 1
            case 2:
                guard input.count - cursor >= 2 else { return nil }
                length = Int(tag >> 2) + 1
                distance = Int(self.littleEndian(input, at: cursor, width: 2))
                cursor += 2
            default:
                guard input.count - cursor >= 4 else { return nil }
                length = Int(tag >> 2) + 1
                distance = Int(self.littleEndian(input, at: cursor, width: 4))
                cursor += 4
            }
            guard distance > 0,
                  distance <= output.count,
                  length <= expectedLength - output.count
            else {
                return nil
            }
            for _ in 0 ..< length {
                output.append(output[output.count - distance])
            }
        }
        return output.count == expectedLength ? output : nil
    }

    private static func readFile(_ url: URL) -> [UInt8]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= self.maximumFileBytes
        else {
            return nil
        }
        return [UInt8](data)
    }

    private static func scanTable(_ file: [UInt8], key: [UInt8], latest: inout LatestEntry) {
        guard file.count >= 48,
              self.littleEndian(file, at: file.count - 8, width: 8) == self.tableMagic
        else {
            return
        }
        var cursor = file.count - 48
        let footerLimit = file.count - 8
        guard self.varint(file, &cursor, limit: footerLimit) != nil,
              self.varint(file, &cursor, limit: footerLimit) != nil,
              let indexOffset = self.varint(file, &cursor, limit: footerLimit),
              let indexSize = self.varint(file, &cursor, limit: footerLimit),
              let index = self.block(file, offset: indexOffset, size: indexSize)
        else {
            return
        }
        self.forEachEntry(in: index) { _, handleRange in
            var handleCursor = handleRange.lowerBound
            guard let offset = self.varint(index, &handleCursor, limit: handleRange.upperBound),
                  let size = self.varint(index, &handleCursor, limit: handleRange.upperBound),
                  let data = self.block(file, offset: offset, size: size)
            else {
                return
            }
            self.forEachEntry(in: data) { internalKey, valueRange in
                guard internalKey.count == key.count + 8,
                      internalKey.starts(with: key)
                else {
                    return
                }
                let trailer = self.littleEndian(internalKey, at: key.count, width: 8)
                latest.offer(
                    sequence: trailer >> 8,
                    value: trailer & 0xFF == 1 ? data[valueRange] : nil)
            }
        }
    }

    private static func block(_ file: [UInt8], offset: Int, size: Int) -> [UInt8]? {
        guard offset <= file.count,
              size <= file.count,
              offset + size + 5 <= file.count
        else {
            return nil
        }
        let contents = Array(file[offset ..< offset + size])
        switch file[offset + size] {
        case 0:
            return contents
        case 1:
            return self.snappyDecompress(contents)
        default:
            return nil
        }
    }

    private static func forEachEntry(
        in block: [UInt8],
        _ body: ([UInt8], Range<Int>) -> Void)
    {
        guard block.count >= 4 else { return }
        let restartCount = Int(self.littleEndian(block, at: block.count - 4, width: 4))
        guard restartCount <= (block.count - 4) / 4 else { return }
        let limit = block.count - 4 - restartCount * 4
        var cursor = 0
        var key: [UInt8] = []
        while cursor < limit {
            guard let shared = self.varint(block, &cursor, limit: limit),
                  let unshared = self.varint(block, &cursor, limit: limit),
                  let valueLength = self.varint(block, &cursor, limit: limit),
                  shared <= key.count,
                  unshared <= limit - cursor,
                  valueLength <= limit - cursor - unshared
            else {
                return
            }
            key.removeSubrange(shared...)
            key.append(contentsOf: block[cursor ..< cursor + unshared])
            cursor += unshared
            body(key, cursor ..< cursor + valueLength)
            cursor += valueLength
        }
    }

    private static func scanLog(_ file: [UInt8], key: [UInt8], latest: inout LatestEntry) {
        var cursor = 0
        var fragments: [UInt8] = []
        while cursor + 7 <= file.count {
            let blockRemaining = self.logBlockSize - cursor % self.logBlockSize
            let length = Int(file[cursor + 4]) | Int(file[cursor + 5]) << 8
            let type = file[cursor + 6]
            let start = cursor + 7
            guard blockRemaining >= 7, type != 0 else {
                // Block trailers and preallocated zero bytes carry no records.
                cursor += blockRemaining
                continue
            }
            guard length <= blockRemaining - 7, length <= file.count - start else {
                return
            }
            cursor = start + length
            switch type {
            case 1:
                fragments.removeAll(keepingCapacity: true)
                self.scanBatch(Array(file[start ..< cursor]), key: key, latest: &latest)
            case 2:
                fragments = Array(file[start ..< cursor])
            case 3:
                fragments.append(contentsOf: file[start ..< cursor])
            case 4:
                fragments.append(contentsOf: file[start ..< cursor])
                self.scanBatch(fragments, key: key, latest: &latest)
                fragments.removeAll(keepingCapacity: true)
            default:
                return
            }
        }
    }

    private static func scanBatch(_ batch: [UInt8], key: [UInt8], latest: inout LatestEntry) {
        guard batch.count >= 12 else { return }
        var sequence = self.littleEndian(batch, at: 0, width: 8)
        let count = self.littleEndian(batch, at: 8, width: 4)
        var cursor = 12
        for _ in 0 ..< count {
            guard cursor < batch.count else { return }
            let type = batch[cursor]
            cursor += 1
            guard type <= 1,
                  let keyLength = self.varint(batch, &cursor, limit: batch.count),
                  keyLength <= batch.count - cursor
            else {
                return
            }
            let keyRange = cursor ..< cursor + keyLength
            cursor += keyLength
            var valueRange: Range<Int>?
            if type == 1 {
                guard let valueLength = self.varint(batch, &cursor, limit: batch.count),
                      valueLength <= batch.count - cursor
                else {
                    return
                }
                valueRange = cursor ..< cursor + valueLength
                cursor += valueLength
            }
            if batch[keyRange].elementsEqual(key) {
                latest.offer(sequence: sequence, value: valueRange.map { batch[$0] })
            }
            sequence &+= 1
        }
    }

    private static func varint(_ bytes: [UInt8], _ cursor: inout Int, limit: Int) -> Int? {
        var result = 0
        var shift = 0
        while cursor < limit, shift <= 56 {
            let byte = bytes[cursor]
            cursor += 1
            result |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return result >= 0 ? result : nil
            }
            shift += 7
        }
        return nil
    }

    private static func littleEndian(_ bytes: [UInt8], at offset: Int, width: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0 ..< width {
            value |= UInt64(bytes[offset + index]) << (8 * index)
        }
        return value
    }
}
