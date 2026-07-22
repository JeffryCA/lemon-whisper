import Darwin
import Foundation
import MLX

struct HeapMetrics: Sendable {
    var nodeCount: Int?
    var agxFamilyBufferCount: Int?
    var status: String
    var rawReportPath: String?
}

struct MetricSample: Codable, Sendable {
    let timestamp: String
    let uptimeSeconds: Double
    let cycle: Int
    let phase: String
    let phaseElapsedMilliseconds: Int
    let mlxActiveBytes: Int
    let mlxCacheBytes: Int
    let physicalFootprintBytes: UInt64?
    let mallocBlocksInUse: UInt64?
    let mallocBytesInUse: UInt64?
    let heapNodeCount: Int?
    let agxFamilyBufferCount: Int?
    let deepSampleStatus: String
    let deepSampleReport: String?
    let transcriptionCharacters: Int?
    let error: String?
}

enum ProcessMetrics {
    static func physicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    static func mallocStatistics() -> (blocks: UInt64, bytes: UInt64)? {
        guard let zone = malloc_default_zone() else { return nil }
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(zone, &statistics)
        return (
            blocks: UInt64(statistics.blocks_in_use),
            bytes: UInt64(statistics.size_in_use)
        )
    }

    static func deepHeapSample(
        processID: Int32,
        reportURL: URL
    ) -> HeapMetrics {
        let heapURL = URL(fileURLWithPath: "/usr/bin/heap")
        guard FileManager.default.isExecutableFile(atPath: heapURL.path) else {
            return HeapMetrics(
                nodeCount: nil,
                agxFamilyBufferCount: nil,
                status: "unavailable: /usr/bin/heap not found",
                rawReportPath: nil
            )
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = heapURL
        process.arguments = [String(processID)]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try data.write(to: reportURL, options: .atomic)

            let output = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                return HeapMetrics(
                    nodeCount: nil,
                    agxFamilyBufferCount: nil,
                    status: "heap exited \(process.terminationStatus)",
                    rawReportPath: reportURL.path
                )
            }

            return HeapMetrics(
                nodeCount: parseHeapNodeCount(output),
                agxFamilyBufferCount: parseAGXFamilyBufferCount(output),
                status: "ok",
                rawReportPath: reportURL.path
            )
        } catch {
            return HeapMetrics(
                nodeCount: nil,
                agxFamilyBufferCount: nil,
                status: "unavailable: \(error.localizedDescription)",
                rawReportPath: nil
            )
        }
    }

    static func parseHeapNodeCount(_ output: String) -> Int? {
        let pattern = #"All zones:\s+([0-9,]+) nodes(?:\s|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        let matches = regex.matches(in: output, range: range)
        guard
            let match = matches.last,
            let valueRange = Range(match.range(at: 1), in: output)
        else { return nil }
        return Int(output[valueRange].replacingOccurrences(of: ",", with: ""))
    }

    static func parseAGXFamilyBufferCount(_ output: String) -> Int? {
        var foundAny = false
        var total = 0
        for line in output.split(separator: "\n") where line.contains("AGX") && line.contains("FamilyBuffer") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let first = fields.first else { continue }
            let digits = first.replacingOccurrences(of: ",", with: "")
            guard let count = Int(digits) else { continue }
            foundAny = true
            total += count
        }
        return foundAny ? total : 0
    }
}
