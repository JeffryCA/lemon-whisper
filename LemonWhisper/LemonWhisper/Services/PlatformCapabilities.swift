import Foundation
import Darwin

enum PlatformCapabilities {
    static var isAppleSilicon: Bool {
        integerValue(for: "hw.optional.arm64") == 1
    }

    static var isIntel: Bool {
        !isAppleSilicon
    }

    static var supportsVoxtral: Bool {
        isAppleSilicon
    }

    private static func integerValue(for name: String) -> Int32 {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname(name, &value, &size, nil, 0)
        return result == 0 ? value : 0
    }
}
