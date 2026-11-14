import Foundation

/// Détecteur de blocages du thread principal (tests de résistance, `FOLUNA_HANGLOG=1`).
/// Toutes les 50 ms, une file de fond envoie un ping au thread principal et note le temps
/// qu'il met à y répondre. Relève aussi l'empreinte mémoire la plus haute.
final class MainThreadWatchdog: @unchecked Sendable {
    struct Window: Sendable {
        var maxStall: Duration = .zero
        var stallsOver250ms = 0
        var peakFootprint: UInt64 = 0
    }

    /// Seuil d'un blocage visible (au-delà, le curseur arc-en-ciel guette).
    static let threshold = Duration.milliseconds(250)

    private let queue = DispatchQueue(label: "foluna.watchdog", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var waiting = false
    private var window = Window()
    private let log: Bool

    /// `log` : chaque blocage au-delà du seuil est écrit sur stderr, horodaté.
    init(log: Bool = false) { self.log = log }

    func start() {
        queue.sync {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    /// Mesures depuis le dernier appel, puis remise à zéro.
    func take() -> Window {
        queue.sync {
            let w = window
            window = Window(peakFootprint: Self.footprint())
            return w
        }
    }

    private func tick() {
        window.peakFootprint = max(window.peakFootprint, Self.footprint())
        guard !waiting else { return }
        waiting = true
        let sent = ContinuousClock.now
        DispatchQueue.main.async { [weak self] in
            let latency = ContinuousClock.now - sent
            guard let self else { return }
            self.queue.async { self.record(latency) }
        }
    }

    private func record(_ latency: Duration) {
        waiting = false
        window.maxStall = max(window.maxStall, latency)
        if latency >= Self.threshold {
            window.stallsOver250ms += 1
            if log {
                let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                       formatOptions: [.withTime, .withColonSeparatorInTime, .withFractionalSeconds])
                FileHandle.standardError.write(Data("HANG \(stamp) \(Self.ms(latency)) ms\n".utf8))
            }
        }
    }

    /// Mémoire comptée par macOS pour le processus (celle du Moniteur d'activité).
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Temps processeur consommé par le processus (utilisateur + système).
    static func cpuTime() -> Duration {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func d(_ t: timeval) -> Duration { .seconds(t.tv_sec) + .microseconds(Int64(t.tv_usec)) }
        return d(usage.ru_utime) + d(usage.ru_stime)
    }

    static func ms(_ d: Duration) -> String {
        String(format: "%.0f", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }
}
