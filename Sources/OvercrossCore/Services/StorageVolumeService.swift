import Foundation

struct StorageVolumeService: Sendable {
    func availableBytes(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        return values.volumeAvailableCapacity.map(Int64.init)
    }
}
