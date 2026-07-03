import SwiftUI
import AppKit

// MARK: - Status model

enum BackupState: Equatable {
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
    // Color the menu bar glyph only for alert states (orange when overdue, red
    // when failed or badly overdue) — these are rare and must catch the eye.
    // Healthy, running and unknown stay nil → adaptive template glyph, legible
    // on any wallpaper. Running feedback comes from the SHAPE flipping to the
    // spinning-arrows symbol, not a color: a fixed tint (e.g. blue) vanishes on
    // a matching menu bar background.
    var menuBarTint: NSColor? {
        switch self {
        case .warning: return .systemOrange
        case .error: return .systemRed
        default: return nil
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

// Healthy states use template images: the system renders them with the menu
// bar's vibrancy material, so they stay legible on any wallpaper in both light
// and dark mode, and stay visually quiet when nothing is wrong. State is
// conveyed by SHAPE there.
//
// Alert states (warning, error/overdue) break that rule on purpose: a stalled
// or failed backup should grab the eye, so the glyph is drawn in its state
// color — orange for overdue-ish, red for failed/badly overdue. A tinted glyph
// can blend into a matching wallpaper, but for the few hours a backup is broken
// that tradeoff is worth it. The shape still differs too, so it reads in both
// the menu bar's grayscale-ish rendering and at a glance by color.
func menuBarImage(symbol: String, tint: NSColor?) -> NSImage {
    var cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
    if let tint { cfg = cfg.applying(.init(paletteColors: [tint])) }
    let img = (NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg)) ?? NSImage()
    img.isTemplate = (tint == nil)
    return img
}

// Render an SF Symbol rotated by `degrees` about its center as a template image,
// so the menu bar tints it with vibrancy like any other glyph. Used to animate
// the running state frame by frame.
func rotatedTemplate(symbol: String, degrees: Double) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
    guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return NSImage() }
    let size = base.size
    let out = NSImage(size: size)
    out.lockFocus()
    if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.rotate(by: CGFloat(degrees * .pi / 180))
        ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
    }
    base.draw(in: NSRect(origin: .zero, size: size))
    out.unlockFocus()
    out.isTemplate = true
    return out
}

// MARK: - Monitor

struct PlanStatus: Identifiable {
    let id: String
    let state: BackupState
    let when: String
}

@MainActor
final class BackupMonitor: ObservableObject {
    @Published var state: BackupState = .unknown { didSet { syncAnimation() } }
    @Published var detail: String = "Connecting…"
    @Published var plans: [PlanStatus] = []
    // The glyph shown in the menu bar. Driven by syncAnimation(): a static image
    // for idle states, or a frame-by-frame rotation while a backup runs.
    @Published var iconImage: NSImage = menuBarImage(symbol: "questionmark.circle", tint: nil)

    private var timer: Timer?
    private var animTimer: Timer?
    private var spinAngle: Double = 0
    let baseURL = "http://127.0.0.1:9898"

    // Per-plan backup interval (hours) from each plan's schedule, used to decide
    // when a plan that last succeeded long ago has gone stale. A successful but
    // old backup is not a healthy one — without this, a plan that stopped running
    // days ago keeps showing green because its last operation was a success.
    private var scheduleHours: [String: Double] = [:]

    // Plans whose schedule is disabled run only on demand, so "last backup is
    // old" is normal, not a problem. They're exempt from the staleness overlay
    // below — otherwise an on-demand plan (e.g. the Odin backup) would falsely
    // go overdue after a day and turn the whole menu bar icon red.
    private var onDemandPlans: Set<String> = []

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
    }

    func refresh() { Task { await poll() } }

    // Spin the arrows glyph while a backup runs by swapping a rotated template
    // image ~12 times a second; show the static state glyph otherwise. Triggered
    // by state's didSet, so it starts the moment the state flips to running
    // (including the optimistic flip in backupNow) and stops when it leaves.
    private func syncAnimation() {
        if state == .running {
            guard animTimer == nil else { return }
            animTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.state == .running else { return }
                    self.spinAngle -= 30
                    self.iconImage = rotatedTemplate(symbol: "arrow.triangle.2.circlepath",
                                                     degrees: self.spinAngle)
                }
            }
        } else {
            animTimer?.invalidate()
            animTimer = nil
            iconImage = menuBarImage(symbol: state.symbol, tint: state.menuBarTint)
        }
    }

    // Trigger an immediate backup for one plan via Backrest's Backup RPC
    // (BackupRequest.value = plan_id). The icon flips to the running state
    // optimistically the moment the request is accepted, so there's instant
    // feedback. The confirming poll is delayed because Backrest needs a beat to
    // register the new operation — polling immediately reads the *previous*
    // SUCCESS and would flip the icon straight back.
    func backupNow(_ planId: String) {
        Task {
            guard let url = URL(string: baseURL + "/v1.Backrest/Backup") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["value": planId])
            req.timeoutInterval = 8
            do {
                _ = try await URLSession.shared.data(for: req)
                state = .running
                detail = "Backup started — \(planId)"
            } catch {
                state = .error
                detail = "Couldn't start backup"
                return
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await poll()
        }
    }

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
        var onDemand: Set<String> = []
        for p in plans {
            guard let id = p["id"] as? String,
                  let sched = p["schedule"] as? [String: Any] else { continue }
            if let disabled = sched["disabled"] as? Bool, disabled { onDemand.insert(id) }
            if let h = sched["maxFrequencyHours"] { map[id] = dblVal(h) }
            else if let d = sched["maxFrequencyDays"] { map[id] = dblVal(d) * 24.0 }
        }
        if !map.isEmpty { scheduleHours = map }
        onDemandPlans = onDemand
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
                if !running && t > 0 && !onDemandPlans.contains(id) {
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
            if monitor.plans.isEmpty {
                Button("Back Up Now") {}.disabled(true)
            } else if monitor.plans.count == 1 {
                Button("Back Up Now") { monitor.backupNow(monitor.plans[0].id) }
            } else {
                Menu("Back Up Now") {
                    ForEach(monitor.plans) { p in
                        Button(p.id) { monitor.backupNow(p.id) }
                    }
                }
            }
            Button("Open Backrest Dashboard") {
                if let u = URL(string: "http://127.0.0.1:9898") { NSWorkspace.shared.open(u) }
            }
            Button("Refresh Now") { monitor.refresh() }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(nsImage: monitor.iconImage)
        }
        .menuBarExtraStyle(.menu)
    }
}
