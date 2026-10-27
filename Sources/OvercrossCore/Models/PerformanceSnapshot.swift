import Foundation
import Darwin

struct PerformanceSnapshot: Equatable, Sendable {
    let capturedAt: Date
    let processResidentMemoryBytes: UInt64?
    let physicalMemoryBytes: UInt64
    let systemUptime: TimeInterval
}

struct PerformanceSnapshotService: Sendable {
    func collect() -> PerformanceSnapshot {
        PerformanceSnapshot(
            capturedAt: Date(),
            processResidentMemoryBytes: processResidentMemoryBytes(),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            systemUptime: ProcessInfo.processInfo.systemUptime
        )
    }

    private func processResidentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }
}
