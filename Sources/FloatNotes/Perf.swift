import AppKit

/// 内存 / 性能诊断。用于 M1 的多窗口性能量化。
enum Perf {

    /// 当前进程常驻内存（MB）
    static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }

    /// 采样：每 0.4 秒记一次内存，返回 (均值, 峰值, 末值)
    static func sample(seconds: Double, completion: @escaping (Double, Double, Double) -> Void) {
        var values: [Double] = []
        let ticks = max(1, Int(seconds / 0.4))
        var remaining = ticks

        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { timer in
            values.append(residentMemoryMB())
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                let avg = values.reduce(0, +) / Double(values.count)
                completion(avg, values.max() ?? 0, values.last ?? 0)
            }
        }
    }

    static func report(windows: Int) -> String {
        let mb = residentMemoryMB()
        return String(format: "常驻内存 %.1f MB | 打开窗口 %d 个 | 平均每窗口 %.1f MB",
                      mb, windows, windows > 0 ? mb / Double(windows) : mb)
    }
}
