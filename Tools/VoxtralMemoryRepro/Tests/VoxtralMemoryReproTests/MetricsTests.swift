import Foundation
import Testing
@testable import VoxtralMemoryRepro

@Test func parsesHeapNodeAndAGXCounts() {
    let report = """
    All zones: 2,170,123 nodes malloced - Sizes: 16[2]

    All zones: 2,170,123 nodes (456789 bytes)

       COUNT      BYTES       AVG   CLASS_NAME
       1,600     102400      64.0   AGXG13XFamilyBuffer
    """

    #expect(ProcessMetrics.parseHeapNodeCount(report) == 2_170_123)
    #expect(ProcessMetrics.parseAGXFamilyBufferCount(report) == 1_600)
}

@Test func reportsZeroWhenHeapHasNoAGXBuffers() {
    let report = "All zones: 178 nodes (11104 bytes)\n"
    #expect(ProcessMetrics.parseAGXFamilyBufferCount(report) == 0)
}

@Test func computesLinearFootprintSlope() {
    let samples = [1, 2, 3].map { cycle in
        MetricSample(
            timestamp: "test",
            uptimeSeconds: Double(cycle),
            cycle: cycle,
            phase: "post-unload",
            phaseElapsedMilliseconds: 0,
            mlxActiveBytes: 0,
            mlxCacheBytes: 0,
            physicalFootprintBytes: UInt64(100 + (cycle * 20)),
            mallocBlocksInUse: nil,
            mallocBytesInUse: nil,
            heapNodeCount: nil,
            agxFamilyBufferCount: nil,
            deepSampleStatus: "not-requested",
            deepSampleReport: nil,
            transcriptionCharacters: nil,
            error: nil
        )
    }

    #expect(Reporter.footprintSlope(samples) == 20)
}

@Test func escapesCSVOnlyWhenNeeded() {
    #expect(Reporter.csvEscape("plain") == "plain")
    #expect(Reporter.csvEscape("a,b") == "\"a,b\"")
    #expect(Reporter.csvEscape("a\"b") == "\"a\"\"b\"")
}
