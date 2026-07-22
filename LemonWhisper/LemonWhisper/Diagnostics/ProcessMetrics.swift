import Darwin

func currentProcessMemoryMB(including processIdentifiers: [pid_t] = []) -> Int {
    let mainProcessBytes = currentTaskPhysicalFootprintBytes()
    let childProcessBytes = processIdentifiers.reduce(into: UInt64(0)) { total, processIdentifier in
        total += physicalFootprintBytes(for: processIdentifier) ?? 0
    }
    return Int((mainProcessBytes + childProcessBytes) / 1_048_576)
}

private func currentTaskPhysicalFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return info.phys_footprint
}

private func physicalFootprintBytes(for processIdentifier: pid_t) -> UInt64? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pid_rusage(
            processIdentifier,
            RUSAGE_INFO_V4,
            UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self)
        )
    }
    guard result == 0 else { return nil }
    return info.ri_phys_footprint
}
