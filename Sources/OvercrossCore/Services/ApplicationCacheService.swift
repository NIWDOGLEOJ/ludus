import Foundation

struct ApplicationCacheService: Sendable {
    let rootURL: URL

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            self.rootURL = LudusStorage.cachesURL
        }
    }

    func usage() -> Int64 {
        usage(at: rootURL)
    }

    func clear() throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: rootURL.path)) != nil {
            throw ApplicationCacheError.invalidRoot
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue else { throw ApplicationCacheError.invalidRoot }

        for item in try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            try FileManager.default.removeItem(at: item)
        }
    }

    private func usage(at url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return fileAllocatedSize(at: url)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey],
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let item as URL in enumerator {
            total += fileAllocatedSize(at: item)
        }
        return total
    }

    private func fileAllocatedSize(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]), values.isRegularFile == true else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}

enum ApplicationCacheError: LocalizedError, Sendable {
    case invalidRoot

    var errorDescription: String? {
        "Ludus's application cache location is not a directory. No files were removed."
    }
}
