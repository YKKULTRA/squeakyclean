import CryptoKit
import Foundation

struct PayloadInspector: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func allocatedSize(at url: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileSizeKey,
            .totalFileAllocatedSizeKey
        ]
        let values = try url.resourceValues(forKeys: keys)
        if values.isDirectory == true, values.isSymbolicLink != true {
            return try directoryAllocatedSize(at: url, keys: keys)
        }
        return Int64(
            values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.totalFileSize
                ?? values.fileSize
                ?? 0
        )
    }

    func contentHash(for url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var hasher = SHA256()
        if values.isSymbolicLink == true {
            // Domain-separate the top-level payload type. A regular file must
            // never verify after being replaced by a symlink to identical bytes.
            hasher.update(data: Data("squeakyclean-v2|symlink\n".utf8))
            let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            hasher.update(data: Data(destination.utf8))
        } else if values.isDirectory == true {
            // Without a type prefix, an empty directory and an empty regular
            // file both reduce to SHA256(empty), weakening restore verification.
            hasher.update(data: Data("squeakyclean-v2|directory\n".utf8))
            try hashDirectory(at: url, into: &hasher)
        } else {
            hasher.update(data: Data("squeakyclean-v2|file\n".utf8))
            try hashFile(at: url, into: &hasher)
        }
        return Self.hexString(from: hasher.finalize())
    }

    private func directoryAllocatedSize(at url: URL, keys: Set<URLResourceKey>) throws -> Int64 {
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CocoaError(
                .fileReadUnknown,
                userInfo: [NSURLErrorKey: url]
            )
        }

        var total: Int64 = 0
        for case let childURL as URL in enumerator {
            try Task.checkCancellation()
            let values = try childURL.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                continue
            }
            total += Int64(
                values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.totalFileSize
                    ?? values.fileSize
                    ?? 0
            )
        }
        if let enumerationError {
            throw enumerationError
        }
        return total
    }

    private func hashDirectory(at root: URL, into hasher: inout SHA256) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CocoaError(
                .fileReadUnknown,
                userInfo: [NSURLErrorKey: root]
            )
        }

        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var children: [URL] = []
        for case let childURL as URL in enumerator {
            try Task.checkCancellation()
            children.append(childURL)
        }
        if let enumerationError {
            throw enumerationError
        }
        children.sort { $0.standardizedFileURL.path < $1.standardizedFileURL.path }

        for childURL in children {
            try Task.checkCancellation()
            let values = try childURL.resourceValues(forKeys: keys)
            let childPath = childURL.standardizedFileURL.path
            let relativePath = childPath.hasPrefix(prefix)
                ? String(childPath.dropFirst(prefix.count))
                : childPath
            let kind = values.isSymbolicLink == true
                ? "symlink"
                : values.isDirectory == true ? "directory" : "file"
            hasher.update(data: Data("\(relativePath)|\(kind)|\(values.fileSize ?? 0)\n".utf8))

            if values.isSymbolicLink == true {
                let destination = try fileManager.destinationOfSymbolicLink(atPath: childURL.path)
                hasher.update(data: Data("->\(destination)\n".utf8))
            } else if values.isRegularFile == true {
                try hashFile(at: childURL, into: &hasher)
            }
        }
    }

    private func hashFile(at url: URL, into hasher: inout SHA256) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: Self.hashChunkSize), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }
    }

    private static func hexString(from digest: SHA256.Digest) -> String {
        digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static let hashChunkSize = 1 << 20
}
