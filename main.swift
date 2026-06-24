import SwiftUI
import AppKit

// MARK: - Status model

enum BackupState {
    case ok, running, warning, error, unknown

    var symbol: String {
        switch self {
        case .ok: return "checkmark.seal.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }
    var color: NSColor {
        switch self {
        case .ok: return .systemGreen
        case .running: return .systemBlue
        case .warning: return .systemOrange
        case .error: return .systemRed
        case .unknown: return .systemGray
        }
    }
    var headline: String {
        switch self {
        case .ok: return "Backups healthy"
        case .running: return "Backup in progress"
        case .warning: return "Finished with warnings"
        case .error: return "Backup failed"
        case .unknown: return "Backrest not reachable"
        }
    }
}

// Menu bar glyphs must be template images: the system renders them with the
// menu bar's vibrancy material, so they stay legible on any wallpaper in both
// light and dark mode. A fixed color (e.g. blue) disappears on a matching
// background. State is conveyed by SHAPE here; color lives in the dropdown,
// where the background is solid and color is reliable.
func menuBarImage(symbol: String) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
    let img = (NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg)) ?? NSImage()
    img.isTemplate = true
    return img
}

// MARK: - Monitor

struct PlanStatus: Identifiable {
    let id: String
    let state: BackupState
    let when: String
}

@MainActor
final class BackupMonitor: ObservableObject {
    @Published var state: BackupState = .unknown
    @Published var detail: String = "Connecting…"
    @Published var plans: [PlanStatus] = []

    private var timer: Timer?
    let baseURL = "http://127.0.0.1:9898"

    // Per-plan backup interval (hours) from each plan's schedule, used to decide
    // when a plan that last succeeded long ago has gone stale. A successful but
    // old backup is not a healthy one — without this, a plan that stopped running
    // days ago keeps showing green because its last operation was a success.
    private var scheduleHours: [String: Double] = [:]

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
    }

    func refresh() { Task { await poll() } }

    private func intVal(_ v: Any?) -> Int {
        if let s = v as? String { return Int(s) ?? 0 }
        if let n = v as? NSNumber { return n.intValue }
        return 0
    }

    private func dblVal(_ v: Any?) -> Double {
        if let s = v as? String { return Double(s) ?? 0 }
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }

    // Pull each plan's backup interval from Backrest's config so staleness is
    // measured against how often that plan is supposed to run, not a fixed guess.
    private func loadSchedules() async {
        guard let url = URL(string: baseURL + "/v1.Backrest/GetConfig") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plans = obj["plans"] as? [[String: Any]] else { return }
        var map: [String: Double] = [:]
        for p in plans {
            guard let id = p["id"] as? String,
                  let sched = p["schedule"] as? [String: Any] else { continue }
            if let h = sched["maxFrequencyHours"] { map[id] = dblVal(h) }
            else if let d = sched["maxFrequencyDays"] { map[id] = dblVal(d) * 24.0 }
        }
        if !map.isEmpty { scheduleHours = map }
    }

    private func mapStatus(_ s: String, running: Bool) -> BackupState {
        if running { return .running }
        switch s {
        case "STATUS_SUCCESS": return .ok
        case "STATUS_WARNING": return .warning
        case "STATUS_ERROR", "STATUS_SYSTEM_CANCELLED": return .error
        default: return .ok
        }
    }

    private func relative(_ msEnd: Int) -> String {
        guard msEnd > 0 else { return "" }
        let secs = Int(Date().timeIntervalSince1970) - msEnd / 1000
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    func poll() async {
        guard let url = URL(string: baseURL + "/v1.Backrest/GetSummaryDashboard") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)
        req.timeoutInterval = 8
        do {
            await loadSchedules()
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let summaries = obj["planSummaries"] as? [[String: Any]] else {
                state = .unknown; detail = "No data from Backrest"; plans = []; return
            }
            if summaries.isEmpty {
                state = .unknown; detail = "No plans configured"; plans = []; return
            }
            var planList: [PlanStatus] = []
            var worst: BackupState = .ok
            var anyRunning = false
            var anyStale = false
            for p in summaries {
                let id = (p["id"] as? String) ?? "?"
                let rb = (p["recentBackups"] as? [String: Any]) ?? [:]
                let statuses = (rb["status"] as? [String]) ?? []
                let times = (rb["timestampMs"] as? [String]) ?? []
                let latest = statuses.first ?? ""
                let running = latest == "STATUS_INPROGRESS" || latest == "STATUS_PENDING"
                if running { anyRunning = true }
                var st = mapStatus(latest, running: running)
                let t = intVal(times.first)

                // Staleness overlay: if the last backup is much older than the
                // plan's interval, downgrade regardless of its success status.
                var stale = false
                if !running && t > 0 {
                    let ageHours = (Date().timeIntervalSince1970 - Double(t) / 1000.0) / 3600.0
                    let interval = scheduleHours[id] ?? 24.0
                    if ageHours > 4 * interval { st = .error; stale = true }
                    else if ageHours > 2 * interval { if st != .error { st = .warning }; stale = true }
                }
                if stale { anyStale = true }

                let label = running ? "running…" : (stale ? relative(t) + " · overdue" : relative(t))
                planList.append(PlanStatus(id: id, state: st, when: label))
                if st == .error { worst = .error }
                else if st == .warning && worst != .error { worst = .warning }
            }
            plans = planList.sorted { $0.id < $1.id }
            state = anyRunning ? .running : worst
            detail = (anyStale && !anyRunning) ? "Backup overdue" : state.headline
        } catch {
            state = .unknown
            detail = "Backrest not reachable"
            plans = []
        }
    }
}

// MARK: - App

@main
struct BackrestStatusApp: App {
    @StateObject private var monitor = BackupMonitor()

    var body: some Scene {
        MenuBarExtra {
            Label(monitor.detail, systemImage: monitor.state.symbol)
                .font(.headline)
                .foregroundStyle(Color(monitor.state.color))
            Divider()
            if monitor.plans.isEmpty {
                Text("No plans").foregroundStyle(.secondary)
            } else {
                ForEach(monitor.plans) { p in
                    Label("\(p.id): \(p.when)", systemImage: p.state.symbol)
                }
            }
            Divider()
            Button("Open Backrest Dashboard") {
                if let u = URL(string: "http://127.0.0.1:9898") { NSWorkspace.shared.open(u) }
            }
            Button("Refresh Now") { monitor.refresh() }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(nsImage: menuBarImage(symbol: monitor.state.symbol))
        }
        .menuBarExtraStyle(.menu)
    }
}
