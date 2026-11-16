#if GHPR_PROFILE
import Foundation
import Darwin
import os

enum PerformanceProfile {
    struct Interval {
        let name: StaticString
        let id: OSSignpostID
        let start: TimeInterval
    }

    private struct Aggregate {
        var count = 0
        var total = 0.0
        var maximum = 0.0
        var samples: [Double] = []

        mutating func add(_ milliseconds: Double) {
            count += 1
            total += milliseconds
            maximum = max(maximum, milliseconds)
            if samples.count < 4096 { samples.append(milliseconds) }
        }

        var json: [String: Any] {
            let sorted = samples.sorted()
            return [
                "count": count, "total_ms": total, "max_ms": maximum,
                "mean_ms": count == 0 ? 0 : total / Double(count),
                "first_samples_p95_ms": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
                "retained_samples": samples.count
            ]
        }
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        let queue = DispatchQueue(label: "com.prdashboard.profile", qos: .utility)
        let log = OSLog(subsystem: "com.prdashboard", category: .pointsOfInterest)
        var timer: DispatchSourceTimer?
        var phase = "startup"
        var metrics: [String: Aggregate] = [:]
        var resources: [[String: Any]] = []
        var previousCPU = 0.0
        var previousTime = ProcessInfo.processInfo.systemUptime
        var heartbeatPending = false
        var started = false
    }

    private static let state = State()

    static func begin(_ name: StaticString) -> Interval {
        let id = OSSignpostID(log: state.log)
        os_signpost(.begin, log: state.log, name: name, signpostID: id)
        return Interval(name: name, id: id, start: ProcessInfo.processInfo.systemUptime)
    }

    static func end(_ interval: Interval) {
        let elapsed = (ProcessInfo.processInfo.systemUptime - interval.start) * 1000
        os_signpost(.end, log: state.log, name: interval.name, signpostID: interval.id)
        record(String(describing: interval.name), milliseconds: elapsed)
    }

    static func record(_ name: String, milliseconds: Double) {
        state.lock.lock()
        let key = "\(state.phase)/\(name)"
        state.metrics[key, default: Aggregate()].add(milliseconds)
        state.lock.unlock()
    }

    static func setPhase(_ name: String) {
        state.lock.lock()
        state.phase = name
        state.lock.unlock()
        os_signpost(.event, log: state.log, name: "ProfilePhase", "%{public}s", name)
    }

    static func start() {
        state.lock.lock()
        guard !state.started else { state.lock.unlock(); return }
        state.started = true
        state.previousCPU = cpuSeconds()
        state.previousTime = ProcessInfo.processInfo.systemUptime
        state.lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: state.queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { sample() }
        state.timer = timer
        timer.resume()
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let cpu = cpuSeconds()
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        state.lock.lock()
        let elapsed = now - state.previousTime
        if elapsed > 0, state.resources.count < 14400 {
            state.resources.append([
                "uptime_seconds": now, "phase": state.phase,
                "cpu_percent_one_core": (cpu - state.previousCPU) / elapsed * 100,
                "peak_resident_bytes": usage.ru_maxrss
            ])
        }
        state.previousTime = now
        state.previousCPU = cpu
        let enqueueHeartbeat = !state.heartbeatPending
        state.heartbeatPending = true
        state.lock.unlock()
        if enqueueHeartbeat {
            DispatchQueue.main.async {
                record("MainQueueDelay", milliseconds: (ProcessInfo.processInfo.systemUptime - now) * 1000)
                state.lock.lock()
                state.heartbeatPending = false
                state.lock.unlock()
            }
        }
    }

    static func finish(completion: @escaping @Sendable (Bool) -> Void) {
        state.timer?.cancel()
        state.queue.async {
            state.lock.lock()
            let report: [String: Any] = [
                "schema": 1, "pid": ProcessInfo.processInfo.processIdentifier,
                "build": "GHPR_PROFILE", "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "logical_cpus": ProcessInfo.processInfo.activeProcessorCount,
                "intervals": state.metrics.mapValues(\.json), "resources": state.resources,
                "gpu": ["status": "external_trace_required", "tool": "Instruments Metal System Trace"],
                "notes": [
                    "View body intervals measure CPU evaluation, not GPU execution or displayed frames.",
                    "Refresh wall time includes suspension and network waits.",
                    "MainQueueDelay is scheduling latency, not FPS.",
                    "Percent CPU is relative to one logical core; it can exceed 100.",
                    "Peak resident memory is a process high-water mark.",
                    "Resources retain the first 14400 samples; interval percentiles use the first 4096 per key."
                ]
            ]
            state.lock.unlock()
            do {
                guard let path = ProcessInfo.processInfo.environment["GHPR_PROFILE_OUTPUT"], !path.isEmpty else {
                    completion(false)
                    return
                }
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
                completion(true)
            } catch {
                Logger(subsystem: "com.prdashboard", category: "PerformanceProfile").error("Profile export failed: \(error.localizedDescription)")
                completion(false)
            }
        }
    }
}
#endif
