import ApplicationServices
import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct WhileItThinksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("WhileItThinks", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 620)
                .task {
                    AppIcon.applyRaccoonDockIcon()
                    await model.refreshAll()
                    await model.ensureDaemonRunning()
                }
        }
        .windowStyle(.titleBar)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            MenuBarRaccoonIcon()
                .help("WhileItThinks")
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 660, height: 620)
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIcon.applyRaccoonDockIcon()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppIcon.applyRaccoonDockIcon()
    }
}

@MainActor
private enum AppIcon {
    static func applyRaccoonDockIcon() {
        guard let image = raccoonImage(size: 512) else { return }
        NSApplication.shared.applicationIconImage = image
    }

    static func raccoonImage(size: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "RaccoonBlink0", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = false
        return image
    }
}

enum Integration: String, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var detail: String {
        switch self {
        case .claude:
            return "Covers Claude Code CLI and the Claude Desktop Code tab through shared user settings."
        case .codex:
            return "Covers Codex CLI and Codex Desktop after one-time hook approval from Codex CLI."
        }
    }
}

private enum OverlayTimingDefaults {
    static let aiDelay = 6
    static let workDelay = 5
    static let commandDelay = 10
    static let cooldown = 120
}

enum OverlayTimingSetting {
    case aiDelay
    case workDelay
    case commandDelay
    case cooldown

    var defaultsKey: String {
        switch self {
        case .aiDelay: return "overlayTiming.aiDelaySeconds"
        case .workDelay: return "overlayTiming.workDelaySeconds"
        case .commandDelay: return "overlayTiming.commandDelaySeconds"
        case .cooldown: return "overlayTiming.cooldownSeconds"
        }
    }

    var defaultValue: Int {
        switch self {
        case .aiDelay: return OverlayTimingDefaults.aiDelay
        case .workDelay: return OverlayTimingDefaults.workDelay
        case .commandDelay: return OverlayTimingDefaults.commandDelay
        case .cooldown: return OverlayTimingDefaults.cooldown
        }
    }

    var range: ClosedRange<Int> {
        switch self {
        case .aiDelay, .workDelay, .commandDelay:
            return 1...60
        case .cooldown:
            return 0...600
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var claudeInstalled = false
    @Published var codexInstalled = false
    @Published var claudeConfigured = false
    @Published var codexConfigured = false
    @Published var claudeNote = "Not checked yet."
    @Published var codexNote = "Not checked yet."
    @Published var claudeHookSummary = "Unknown"
    @Published var codexHookSummary = "Unknown"
    @Published var daemonStatus = "Not running"
    @Published var daemonDetail = "Click Start Daemon to launch the local event receiver."
    @Published var notificationStatus = "Not requested"
    @Published var accessibilityStatus = AppModel.accessibilityTrustStatus()
    @Published var launchAtLoginStatus = "Not configured"
    @Published var lastOutput = ""
    @Published var lastEventSummary = "No Claude or Codex hook event received since the app opened."
    @Published var lastActionSummary = "Hooks are event-driven. Nothing runs every 8 seconds."
    @Published var codexTrustAcknowledged = UserDefaults.standard.bool(forKey: "codexHooks.trustAcknowledged")
    @Published var aiOverlayDelaySeconds = OverlayTimingDefaults.aiDelay
    @Published var workOverlayDelaySeconds = OverlayTimingDefaults.workDelay
    @Published var commandOverlayDelaySeconds = OverlayTimingDefaults.commandDelay
    @Published var overlayCooldownSeconds = OverlayTimingDefaults.cooldown
    @Published var isBusy = false
    @Published var isDaemonStarting = false

    private var daemonProcess: Process?
    private var daemonOutputBuffer = ""
    private var actionLogOffset: UInt64 = 0
    private var actionLogWatcher: Task<Void, Never>?
    private var accessibilityWatcher: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var seenActionIDs = Set<String>()
    private var pendingOverlayTasks: [String: Task<Void, Never>] = [:]
    private var pendingOverlayStates: [String: String] = [:]
    private var visibleOverlayKey: String?
    private var overlayCooldownUntil = Date.distantPast
    private let overlayPresenter = OverlayPresenter()

    init() {
        aiOverlayDelaySeconds = Self.storedTiming(for: .aiDelay)
        workOverlayDelaySeconds = Self.storedTiming(for: .workDelay)
        commandOverlayDelaySeconds = Self.storedTiming(for: .commandDelay)
        overlayCooldownSeconds = Self.storedTiming(for: .cooldown)
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncAccessibilityStatus()
            }
        }
    }

    var bundleDirectory: URL {
        Bundle.main.bundleURL
    }

    var overlayTimingDescription: String {
        "AI \(formattedDuration(aiOverlayDelaySeconds)), build/test/install \(formattedDuration(workOverlayDelaySeconds)), generic command \(formattedDuration(commandOverlayDelaySeconds)), cooldown \(formattedDuration(overlayCooldownSeconds))."
    }

    var codexTrustStatusText: String {
        if !codexInstalled {
            return "Not installed"
        }
        if !codexConfigured {
            return "Needs repair"
        }
        return codexTrustAcknowledged ? "Marked trusted" : "Needs Codex approval"
    }

    var isRunningFromApplications: Bool {
        bundleDirectory.path.hasPrefix("/Applications/")
    }

    var installLocationMessage: String {
        if isRunningFromApplications {
            return "Installed in /Applications. Hook paths will remain stable."
        }
        return "Move WhileItThinks.app to /Applications before enabling integrations. Hooks use the app's absolute path."
    }

    var hookPath: String {
        binaryURL("whileitthinks-hook").path
    }

    var actionsLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("WhileItThinks")
            .appendingPathComponent("actions.jsonl")
    }

    private static func storedTiming(for setting: OverlayTimingSetting) -> Int {
        guard UserDefaults.standard.object(forKey: setting.defaultsKey) != nil else {
            return setting.defaultValue
        }
        return clampedTiming(UserDefaults.standard.integer(forKey: setting.defaultsKey), for: setting)
    }

    private static func clampedTiming(_ seconds: Int, for setting: OverlayTimingSetting) -> Int {
        min(max(seconds, setting.range.lowerBound), setting.range.upperBound)
    }

    func formattedDuration(_ seconds: Int) -> String {
        if seconds == 0 {
            return "off"
        }
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if remainder == 0 {
            return "\(minutes)m"
        }
        return "\(minutes)m \(remainder)s"
    }

    func setOverlayTiming(_ setting: OverlayTimingSetting, seconds: Int) {
        let value = Self.clampedTiming(seconds, for: setting)
        switch setting {
        case .aiDelay:
            aiOverlayDelaySeconds = value
        case .workDelay:
            workOverlayDelaySeconds = value
        case .commandDelay:
            commandOverlayDelaySeconds = value
        case .cooldown:
            overlayCooldownSeconds = value
            if value == 0 {
                overlayCooldownUntil = Date.distantPast
            }
        }
        UserDefaults.standard.set(value, forKey: setting.defaultsKey)
    }

    func resetOverlayTimingDefaults() {
        setOverlayTiming(.aiDelay, seconds: OverlayTimingDefaults.aiDelay)
        setOverlayTiming(.workDelay, seconds: OverlayTimingDefaults.workDelay)
        setOverlayTiming(.commandDelay, seconds: OverlayTimingDefaults.commandDelay)
        setOverlayTiming(.cooldown, seconds: OverlayTimingDefaults.cooldown)
        lastActionSummary = "Overlay timing reset to recommended defaults."
    }

    func refreshAll() async {
        startActionLogWatcher()
        startAccessibilityWatcher()
        await refreshStatus()
        await refreshNotificationStatus()
        syncAccessibilityStatus()
    }

    func refreshStatus() async {
        let result = await runCLI(["--hook-path", hookPath, "status"])
        lastOutput = result.display
        guard result.exitCode == 0 else {
            claudeNote = "Could not read status."
            codexNote = result.display
            return
        }
        parseStatus(result.stdout)
    }

    func setIntegration(_ integration: Integration, enabled: Bool) async {
        isBusy = true
        defer { isBusy = false }

        let command = enabled ? "install" : "uninstall"
        let result = await runCLI(["--hook-path", hookPath, command, integration.rawValue])
        lastOutput = result.display
        if integration == .codex {
            setCodexTrustAcknowledged(false)
        }
        await refreshStatus()
    }

    func ensureDaemonRunning() async {
        isDaemonStarting = true
        daemonStatus = "Checking"
        daemonDetail = "Checking whether the local event daemon is already accepting events."
        defer { isDaemonStarting = false }

        if await daemonHealthCheck() {
            if daemonProcess == nil {
                daemonStatus = "Running (external)"
                daemonDetail = "A daemon is already running. If overlays do not follow real Claude/Codex events, use Restart Daemon to replace it with this app's bundled daemon."
            } else {
                daemonStatus = "Running"
                daemonDetail = "Daemon is running at 127.0.0.1:47328 and the local Unix socket."
            }
            return
        }

        let daemonURL = binaryURL("whileitthinksd")
        guard FileManager.default.isExecutableFile(atPath: daemonURL.path) else {
            daemonStatus = "Missing bundled daemon"
            daemonDetail = "Could not find whileitthinksd inside the app bundle."
            return
        }

        daemonStatus = "Starting"
        daemonDetail = "Launching bundled whileitthinksd. This should take less than a second."

        let process = Process()
        process.executableURL = daemonURL
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            daemonProcess = process
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task { @MainActor in
                    self?.consumeDaemonOutput(data)
                }
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            if await daemonHealthCheck() {
                daemonStatus = "Running"
                daemonDetail = "Started successfully. Claude and Codex hooks can now send local wait-state events."
            } else {
                daemonStatus = "Starting"
                daemonDetail = "Daemon process launched, but the health check has not answered yet. Click Refresh in a moment."
            }
        } catch {
            daemonStatus = "Failed to start: \(error.localizedDescription)"
            daemonDetail = "The bundled daemon could not be launched. Check Diagnostics for command output."
        }
    }

    func restartDaemonFromApp() async {
        isDaemonStarting = true
        daemonStatus = "Restarting"
        daemonDetail = "Stopping existing WhileItThinks daemons and starting the bundled daemon."

        daemonProcess?.terminate()
        daemonProcess = nil

        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            process.arguments = ["-x", "whileitthinksd"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }.value

        try? await Task.sleep(nanoseconds: 350_000_000)
        isDaemonStarting = false
        await ensureDaemonRunning()
    }

    func requestNotifications() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            notificationStatus = granted ? "Enabled" : "Denied in System Settings"
        } catch {
            notificationStatus = "Failed: \(error.localizedDescription)"
        }
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityStatus = trusted ? "Granted" : "Waiting for approval"
        startAccessibilityWatcher()
        openAccessibilitySettings()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func setCodexTrustAcknowledged(_ acknowledged: Bool) {
        codexTrustAcknowledged = acknowledged
        UserDefaults.standard.set(acknowledged, forKey: "codexHooks.trustAcknowledged")
    }

    func configureLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                launchAtLoginStatus = "Enabled"
            } else {
                try SMAppService.mainApp.unregister()
                launchAtLoginStatus = "Disabled"
            }
        } catch {
            launchAtLoginStatus = "Could not update: \(error.localizedDescription)"
        }
    }

    func sendTestClaudeEvent() async {
        await sendSyntheticShellEvent(source: "claude-code", label: "Claude shell", command: "sleep 12", simulatedSeconds: 11)
    }

    func sendTestCodexEvent() async {
        await sendSyntheticShellEvent(source: "codex", label: "Codex test", command: "pnpm test", simulatedSeconds: 6)
    }

    func sendTestAiGenerationEvent() async {
        await ensureDaemonRunning()
        lastActionSummary = "Synthetic AI generation started. Overlay appears after 6 seconds if it is still running."
        let start = await runCLI(["test-event", "--source", "claude-code", "--event", "agent_started", "--command", ""])
        lastOutput = start.display
        try? await Task.sleep(nanoseconds: 7_000_000_000)
        let finish = await runCLI(["test-event", "--source", "claude-code", "--event", "agent_stopped", "--command", ""])
        lastOutput = [start.display, finish.display].filter { !$0.isEmpty }.joined(separator: "\n")
        postNotification(title: "WhileItThinks test", body: "Synthetic AI generation completed.")
    }

    func sendTestPermissionEvent() async {
        await ensureDaemonRunning()
        let claude = await runCLI(["test-event", "--source", "claude-code", "--event", "permission_requested", "--command", ""])
        lastOutput = claude.display
        postNotification(title: "WhileItThinks test", body: "Synthetic permission event sent.")
    }

    private func sendSyntheticShellEvent(source: String, label: String, command: String, simulatedSeconds: UInt64) async {
        await ensureDaemonRunning()
        lastActionSummary = "\(label) synthetic start sent. Waiting long enough to cross the overlay threshold."
        let start = await runCLI(["test-event", "--source", source, "--event", "shell_started", "--command", command])
        lastOutput = start.display
        try? await Task.sleep(nanoseconds: simulatedSeconds * 1_000_000_000)
        let finish = await runCLI(["test-event", "--source", source, "--event", "shell_finished", "--command", command])
        lastOutput = [start.display, finish.display].filter { !$0.isEmpty }.joined(separator: "\n")
        postNotification(title: "WhileItThinks test", body: "\(label) completed.")
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationStatus = "Enabled"
        case .denied:
            notificationStatus = "Denied in System Settings"
        case .notDetermined:
            notificationStatus = "Not requested"
        @unknown default:
            notificationStatus = "Unknown"
        }
    }

    private func syncAccessibilityStatus() {
        accessibilityStatus = Self.accessibilityTrustStatus()
    }

    private static func accessibilityTrustStatus() -> String {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options) ? "Granted" : "Not granted"
    }

    private func startAccessibilityWatcher() {
        guard accessibilityWatcher == nil else { return }
        accessibilityWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.syncAccessibilityStatus()
            }
        }
    }

    private func parseStatus(_ output: String) {
        guard let data = output.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            claudeNote = output
            codexNote = output
            return
        }

        for item in items {
            guard let integration = item["integration"] as? String else { continue }
            let installed = item["installed"] as? Bool ?? false
            if integration == "claude" {
                claudeInstalled = installed
                claudeConfigured = item["configured"] as? Bool ?? false
                claudeNote = integrationNextStep(.claude, item: item)
                claudeHookSummary = hookSummary(item)
            } else if integration == "codex" {
                codexInstalled = installed
                codexConfigured = item["configured"] as? Bool ?? false
                if !codexConfigured {
                    setCodexTrustAcknowledged(false)
                }
                codexNote = integrationNextStep(.codex, item: item)
                codexHookSummary = hookSummary(item)
            }
        }
    }

    private func integrationNextStep(_ integration: Integration, item: [String: Any]) -> String {
        let installed = item["installed"] as? Bool ?? false
        let configured = item["configured"] as? Bool ?? false
        let pathExists = item["expected_hook_path_exists"] as? Bool ?? false
        let stalePaths = item["stale_hook_paths"] as? [String] ?? []
        let missingEvents = item["missing_events"] as? [String] ?? []

        if !installed {
            return "Turn this on to install hooks."
        }
        if !stalePaths.isEmpty {
            return "Hooks point at an old app copy. Toggle off and on to repair."
        }
        if !pathExists {
            return "Hook binary missing. Reinstall the app in /Applications."
        }
        if !missingEvents.isEmpty || !configured {
            return "Hooks are incomplete. Toggle off and on to repair."
        }

        switch integration {
        case .claude:
            return "Ready."
        case .codex:
            return codexTrustAcknowledged
                ? "Ready."
                : "Open Codex CLI, run /hooks, approve WhileItThinks, then mark it done here."
        }
    }

    private func hookSummary(_ item: [String: Any]) -> String {
        let installed = item["installed_hook_count"] as? Int ?? 0
        let expected = item["expected_hook_count"] as? Int ?? 0
        let configured = item["configured"] as? Bool ?? false
        let pathExists = item["expected_hook_path_exists"] as? Bool ?? false
        let stalePaths = item["stale_hook_paths"] as? [String] ?? []
        let integration = item["integration"] as? String ?? ""
        if integration == "codex", configured, !codexTrustAcknowledged {
            return "Needs trust"
        }
        if configured {
            return "Ready (\(installed)/\(expected) hooks)"
        }
        if !stalePaths.isEmpty {
            return "Stale path (\(installed)/\(expected) hooks)"
        }
        if installed > 0 && !pathExists {
            return "Hook binary missing"
        }
        if installed > 0 {
            return "Needs repair (\(installed)/\(expected) hooks)"
        }
        return "Not installed"
    }

    private func consumeDaemonOutput(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        daemonOutputBuffer += chunk
        let parts = daemonOutputBuffer.split(separator: "\n", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return }

        for line in parts.dropLast() {
            handleDaemonLine(String(line))
        }
        daemonOutputBuffer = String(parts.last ?? "")
    }

    private func handleDaemonLine(_ line: String) {
        guard line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? [String: Any] else {
            return
        }

        if let sanitized = json["sanitized"] as? [String: Any],
           let id = sanitized["id"] as? String {
            if seenActionIDs.contains(id) {
                return
            }
            seenActionIDs.insert(id)
            if seenActionIDs.count > 400 {
                seenActionIDs.removeAll(keepingCapacity: true)
            }
        }

        let kind = action["kind"] as? String ?? "none"
        let message = action["message"] as? String ?? "WhileItThinks event"
        updateLastEventSummary(json: json, action: action, message: message)
        lastOutput = line

        if kind == "started" {
            scheduleOverlayIfStillWaiting(json: json, action: action, message: message)
        } else if kind == "finished" {
            finishOverlay(json: json)
            postNotification(title: "WhileItThinks", body: message)
        } else if kind == "permission" {
            postNotification(title: "Approval needed", body: message)
        }
    }

    private func startActionLogWatcher() {
        guard actionLogWatcher == nil else { return }
        let url = actionsLogURL
        actionLogOffset = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0

        actionLogWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self?.readActionLogIncrement()
            }
        }
    }

    private func readActionLogIncrement() async {
        let url = actionsLogURL
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let currentSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        if currentSize < actionLogOffset {
            actionLogOffset = 0
        }
        guard currentSize > actionLogOffset else { return }

        do {
            try handle.seek(toOffset: actionLogOffset)
            let data = try handle.readToEnd() ?? Data()
            actionLogOffset = currentSize
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            for line in chunk.split(separator: "\n") {
                handleDaemonLine(String(line))
            }
        } catch {
            return
        }
    }

    private func updateLastEventSummary(json: [String: Any], action: [String: Any], message: String) {
        guard let sanitized = json["sanitized"] as? [String: Any] else {
            lastEventSummary = message
            lastActionSummary = message
            return
        }

        let source = sanitized["source"] as? String ?? "unknown"
        let event = sanitized["raw_event_name"] as? String ?? sanitized["kind"] as? String ?? "event"
        let kind = sanitized["kind"] as? String ?? "event"
        let command = sanitized["command_summary"] as? String
        let waitState = action["wait_state"] as? String

        var parts = ["\(source) \(event)", kind]
        if let command, !command.isEmpty {
            parts.append(command)
        }
        if let waitState, !waitState.isEmpty {
            parts.append(waitState)
        }

        lastEventSummary = parts.joined(separator: " -> ")
        lastActionSummary = message
    }

    private func scheduleOverlayIfStillWaiting(json: [String: Any], action: [String: Any], message: String) {
        let key = overlayKey(json: json)
        let waitState = action["wait_state"] as? String ?? "unknown"
        let delay = overlayDelaySeconds(for: waitState)

        if pendingOverlayStates[key] == waitState {
            return
        }

        pendingOverlayTasks[key]?.cancel()
        pendingOverlayStates[key] = waitState

        pendingOverlayTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }

            await MainActor.run {
                guard let self else { return }
                self.pendingOverlayTasks[key] = nil
                self.pendingOverlayStates[key] = nil

                guard Date() >= self.overlayCooldownUntil else {
                    self.lastActionSummary = "Overlay suppressed by cooldown; event was still recorded."
                    return
                }
                self.visibleOverlayKey = key
                self.overlayCooldownUntil = Date().addingTimeInterval(TimeInterval(self.overlayCooldownSeconds))
                self.overlayPresenter.show(message: self.overlayCopy(for: waitState, fallback: message))
            }
        }
    }

    private func finishOverlay(json: [String: Any]) {
        let key = overlayKey(json: json)
        pendingOverlayTasks[key]?.cancel()
        pendingOverlayTasks[key] = nil
        pendingOverlayStates[key] = nil

        if visibleOverlayKey == key {
            overlayPresenter.hide()
            visibleOverlayKey = nil
        }
    }

    private func overlayKey(json: [String: Any]) -> String {
        guard let sanitized = json["sanitized"] as? [String: Any] else {
            return "unknown"
        }
        if let session = sanitized["session_hash"] as? String, !session.isEmpty {
            return "session:\(session)"
        }
        if let cwd = sanitized["cwd_hash"] as? String, !cwd.isEmpty {
            return "cwd:\(cwd)"
        }
        let source = sanitized["source"] as? String ?? "unknown"
        let surface = sanitized["surface"] as? String ?? "unknown"
        return "\(source):\(surface)"
    }

    private func overlayDelaySeconds(for waitState: String) -> Double {
        switch waitState {
        case "build_running", "test_running", "package_installing", "docker_running", "xcode_building":
            return Double(workOverlayDelaySeconds)
        case "command_running":
            return Double(commandOverlayDelaySeconds)
        case "ai_generating", "agent_running_tools":
            return Double(aiOverlayDelaySeconds)
        default:
            return Double(aiOverlayDelaySeconds)
        }
    }

    private func overlayCopy(for waitState: String, fallback: String) -> String {
        switch waitState {
        case "ai_generating":
            return "AI is still thinking"
        case "test_running":
            return "Tests are still running"
        case "build_running", "xcode_building":
            return "Build is still running"
        case "package_installing":
            return "Install is still running"
        case "docker_running":
            return "Docker is still working"
        case "agent_running_tools":
            return "Agent tools are still running"
        default:
            return fallback
        }
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func runCLI(_ arguments: [String]) async -> CommandResult {
        let cliURL = binaryURL("whileitthinks-cli")
        return await Task.detached {
            guard FileManager.default.isExecutableFile(atPath: cliURL.path) else {
                return CommandResult(exitCode: 127, stdout: "", stderr: "Missing bundled CLI at \(cliURL.path)")
            }

            let process = Process()
            process.executableURL = cliURL
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
                process.waitUntilExit()
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                return CommandResult(
                    exitCode: process.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                )
            } catch {
                return CommandResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
            }
        }.value
    }

    private func daemonHealthCheck() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:47328/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func binaryURL(_ name: String) -> URL {
        let bundleBinary = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: bundleBinary.path) {
            return bundleBinary
        }

        if let override = ProcessInfo.processInfo.environment["WHILEITTHINKS_BIN_DIR"] {
            let overrideDir = URL(fileURLWithPath: override)
            if name == "whileitthinks-cli" {
                return overrideDir.appendingPathComponent("whileitthinks")
            }
            return overrideDir.appendingPathComponent(name)
        }

        if name == "whileitthinks-cli" {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("target")
                .appendingPathComponent("debug")
                .appendingPathComponent("whileitthinks")
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("target")
            .appendingPathComponent("debug")
            .appendingPathComponent(name)
    }
}

@MainActor
private final class OverlayPresenter {
    private var panel: NSPanel?
    private let panelSize = NSSize(width: 386, height: 154)

    func show(message: String) {
        if panel == nil {
            panel = makePanel()
        }
        let content = OverlayBanner(message: message) { [weak self] in
            self?.hide()
        }
        panel?.contentView = NSHostingView(rootView: content)
        positionPanel()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        return panel
    }

    private func positionPanel() {
        guard let panel else { return }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        let origin = NSPoint(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24)
        panel.setFrameOrigin(origin)
    }
}

private enum AppTheme {
    static let page = Color(red: 0.965, green: 0.972, blue: 0.965)
    static let panel = Color(red: 0.995, green: 0.992, blue: 0.975)
    static let ink = Color(red: 0.09, green: 0.11, blue: 0.11)
    static let muted = Color(red: 0.43, green: 0.46, blue: 0.45)
    static let line = Color(red: 0.10, green: 0.14, blue: 0.13).opacity(0.10)
    static let green = Color(red: 0.05, green: 0.58, blue: 0.44)
    static let coral = Color(red: 0.82, green: 0.20, blue: 0.24)
    static let gold = Color(red: 0.89, green: 0.62, blue: 0.16)
}

private struct OverlayBanner: View {
    let message: String
    let onDismiss: () -> Void
    @State private var didEnter = false

    var body: some View {
        HStack(spacing: 14) {
            RaccoonBlinkingAvatar(size: 88)
                .offset(x: didEnter ? 0 : -18, y: didEnter ? 0 : 4)
                .opacity(didEnter ? 1 : 0)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The raccoon is on watch")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.green)
                        Text(message)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AppTheme.ink)
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.82))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }

                Text("Blink slowly 8 times. Your code is busy; your eyes can step away.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(2)

                HStack(spacing: 5) {
                    ForEach(0..<8, id: \.self) { index in
                        Capsule()
                            .fill(index < 3 ? AppTheme.green : Color(red: 0.74, green: 0.79, blue: 0.76))
                            .frame(width: index < 3 ? 20 : 9, height: 5)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 386, height: 154, alignment: .leading)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.panel)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.green)
                    .frame(width: 7)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.line, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.20), radius: 22, x: 0, y: 12)
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                didEnter = true
            }
        }
    }
}

private struct RaccoonBlinkingAvatar: View {
    let size: CGFloat
    @State private var tick = 0
    private let sequence = [0, 0, 0, 0, 1, 2, 3, 0, 0, 0]
    private let timer = Timer.publish(every: 0.24, on: .main, in: .common).autoconnect()

    var body: some View {
        RaccoonFrameImage(frame: sequence[tick % sequence.count], size: size)
            .shadow(color: AppTheme.green.opacity(0.20), radius: 14, x: 0, y: 8)
            .onReceive(timer) { _ in
                tick = (tick + 1) % sequence.count
            }
    }
}

private struct RaccoonFrameImage: View {
    let frame: Int
    let size: CGFloat

    var body: some View {
        Group {
            if let image = Self.image(for: frame) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                FallbackRaccoonFace(blinkLevel: blinkLevel)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(width: size, height: size)
    }

    private var blinkLevel: CGFloat {
        switch frame {
        case 1, 3: return 0.55
        case 2: return 1.0
        default: return 0.0
        }
    }

    private static func image(for frame: Int) -> NSImage? {
        if let url = Bundle.main.url(forResource: "RaccoonBlink\(frame)", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}

private struct MenuBarRaccoonIcon: View {
    var body: some View {
        Group {
            if let image = Self.image() {
                Image(nsImage: image)
                    .renderingMode(.original)
            } else {
                Image(systemName: "pawprint.fill")
            }
        }
        .frame(width: 18, height: 18)
    }

    private static func image() -> NSImage? {
        AppIcon.raccoonImage(size: 18)
    }
}

private struct FallbackRaccoonFace: View {
    let blinkLevel: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [
                    Color(red: 0.12, green: 0.19, blue: 0.20),
                    Color(red: 0.22, green: 0.30, blue: 0.28)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
            Triangle()
                .fill(Color(red: 0.16, green: 0.19, blue: 0.19))
                .frame(width: 24, height: 22)
                .rotationEffect(.degrees(-28))
                .offset(x: -23, y: -24)
            Triangle()
                .fill(Color(red: 0.16, green: 0.19, blue: 0.19))
                .frame(width: 24, height: 22)
                .rotationEffect(.degrees(28))
                .offset(x: 23, y: -24)
            Circle()
                .fill(Color(red: 0.70, green: 0.73, blue: 0.68))
                .frame(width: 58, height: 50)
                .offset(y: 3)
            Capsule()
                .fill(Color(red: 0.09, green: 0.12, blue: 0.12))
                .frame(width: 56, height: 18)
                .offset(y: -4)
            HStack(spacing: 15) {
                fallbackEye
                fallbackEye
            }
            .offset(y: -5)
            Capsule()
                .fill(Color(red: 0.90, green: 0.85, blue: 0.72))
                .frame(width: 28, height: 18)
                .offset(y: 16)
            Circle()
                .fill(Color(red: 0.07, green: 0.09, blue: 0.09))
                .frame(width: 8, height: 6)
                .offset(y: 11)
        }
    }

    private var fallbackEye: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white)
            .frame(width: 10, height: max(2, 10 * (1 - blinkLevel)))
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct CommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var display: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

private enum AppSection: String, CaseIterable, Identifiable {
    case setup
    case tutorial
    case privacy
    case diagnostics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setup: return "Setup"
        case .tutorial: return "Tutorial"
        case .privacy: return "Privacy"
        case .diagnostics: return "Diagnostics"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .setup: return "switch.2"
        case .tutorial: return "list.bullet.rectangle"
        case .privacy: return "lock.shield"
        case .diagnostics: return "waveform.path.ecg"
        case .settings: return "gearshape.fill"
        }
    }
}

private enum Tone {
    case good
    case warning
    case danger
    case neutral

    var color: Color {
        switch self {
        case .good: return AppTheme.green
        case .warning: return AppTheme.gold
        case .danger: return AppTheme.coral
        case .neutral: return Color(red: 0.45, green: 0.49, blue: 0.48)
        }
    }
}

private struct ContentView: View {
    @State private var selection: AppSection = .setup

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selection: $selection)
            Rectangle()
                .fill(AppTheme.line)
                .frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    selectedContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
            .background(AppTheme.page)
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selection {
        case .setup:
            SetupView()
        case .tutorial:
            TutorialView()
        case .privacy:
            PrivacyView()
        case .diagnostics:
            DiagnosticsView()
        case .settings:
            SettingsView()
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: AppSection

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                RaccoonBlinkingAvatar(size: 58)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WhileItThinks")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppTheme.ink)
                    Text("Local wait-state router")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.muted)
                }
            }
            .padding(.top, 8)

            SidebarStatus(title: "Daemon", value: model.daemonStatus, tone: model.daemonStatus.contains("Running") ? .good : .warning)

            VStack(spacing: 6) {
                ForEach(AppSection.allCases) { section in
                    SidebarButton(section: section, isSelected: selection == section) {
                        selection = section
                    }
                }
            }

            Spacer()

            Button {
                Task { await model.refreshAll() }
            } label: {
                Label("Refresh Status", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(SidebarFooterButtonStyle())
        }
        .padding(18)
        .frame(width: 238)
        .background(Color(red: 0.925, green: 0.945, blue: 0.935))
    }
}

private struct SidebarButton: View {
    let section: AppSection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(section.title, systemImage: section.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : AppTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(isSelected ? AppTheme.green : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct SidebarStatus: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let value: String
    let tone: Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AppTheme.muted)
            HStack(spacing: 8) {
                Circle()
                    .fill(tone.color)
                    .frame(width: 8, height: 8)
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                if title == "Daemon" {
                    Button {
                        Task { await model.restartDaemonFromApp() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.green)
                    .disabled(model.isDaemonStarting)
                    .help("Restart daemon")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.line, lineWidth: 1))
    }
}

private struct SidebarFooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AppTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.white.opacity(configuration.isPressed ? 0.44 : 0.70))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.line, lineWidth: 1))
    }
}

private struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("WhileItThinks")
        Text("Daemon: \(model.daemonStatus)")
        Text(model.daemonDetail)
            .font(.caption)
        Divider()
        Button("Open WhileItThinks") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button(model.daemonStatus.contains("Running") ? "Daemon Running" : "Start Daemon") {
            Task { await model.ensureDaemonRunning() }
        }
        .disabled(model.isDaemonStarting)
        Button("Restart Daemon") {
            Task { await model.restartDaemonFromApp() }
        }
        .disabled(model.isDaemonStarting)
        Divider()
        Button("Send Claude Test") {
            Task { await model.sendTestClaudeEvent() }
        }
        Button("Send Codex Test") {
            Task { await model.sendTestCodexEvent() }
        }
        Divider()
        Button("Quit WhileItThinks") {
            NSApplication.shared.terminate(nil)
        }
    }
}

private struct SetupView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeroPanel()

            PermissionStatusStrip()

            InfoBand(text: model.installLocationMessage, systemImage: model.isRunningFromApplications ? "checkmark.seal.fill" : "exclamationmark.triangle.fill", tone: model.isRunningFromApplications ? .good : .warning)
            if !model.daemonStatus.contains("Running") {
                InfoBand(text: model.daemonDetail, systemImage: "info.circle.fill", tone: .neutral)
            }

            SectionTitle("Integrations", subtitle: "Enable user-level hooks for Claude Code and Codex. Existing config is backed up and merged.")

            IntegrationRow(
                integration: .claude,
                enabled: model.claudeInstalled,
                configured: model.claudeConfigured,
                hookSummary: model.claudeHookSummary,
                note: model.claudeNote,
                isBusy: model.isBusy
            ) { enabled in
                Task { await model.setIntegration(.claude, enabled: enabled) }
            }

            IntegrationRow(
                integration: .codex,
                enabled: model.codexInstalled,
                configured: model.codexConfigured,
                hookSummary: model.codexHookSummary,
                note: model.codexNote,
                isBusy: model.isBusy
            ) { enabled in
                Task { await model.setIntegration(.codex, enabled: enabled) }
            }

            TriggerStatusCard()
        }
    }
}

private struct HeroPanel: View {
    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            RaccoonBlinkingAvatar(size: 82)
            VStack(alignment: .leading, spacing: 6) {
                Text("WhileItThinks")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(AppTheme.ink)
                Text("Claude Code or Codex is thinking. Your eyes get the break.")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Label("Local only", systemImage: "lock.shield.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppTheme.green)
                Text("No prompts, no cloud, no webcam.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.muted)
            }
        }
        .padding(20)
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.line, lineWidth: 1))
    }
}

private struct PermissionStatusStrip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            PermissionStatusCard(
                title: "Notifications",
                value: model.notificationStatus,
                tone: model.notificationStatus == "Enabled" ? .good : .neutral,
                actionTitle: model.notificationStatus == "Enabled" ? nil : "Allow",
                actionIcon: "bell.badge.fill"
            ) {
                Task { await model.requestNotifications() }
            }

            PermissionStatusCard(
                title: "Accessibility",
                value: model.accessibilityStatus,
                tone: model.accessibilityStatus == "Granted" ? .good : .neutral,
                actionTitle: model.accessibilityStatus == "Granted" ? "Open" : "Grant",
                actionIcon: "hand.raised.fill"
            ) {
                model.requestAccessibility()
            }
        }
    }
}

private struct PermissionStatusCard: View {
    let title: String
    let value: String
    let tone: Tone
    var actionTitle: String?
    var actionIcon: String?
    var disabled = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Circle()
                    .fill(tone.color)
                    .frame(width: 8, height: 8)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppTheme.muted)
                Spacer()
                if let actionTitle, let actionIcon {
                    Button(action: action) {
                        Label(actionTitle, systemImage: actionIcon)
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(CompactButtonStyle(tone: tone))
                    .disabled(disabled)
                }
            }

            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.86)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .background(Color.white.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.line, lineWidth: 1))
    }
}

private struct CompactButtonStyle: ButtonStyle {
    let tone: Tone

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(tone.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tone.color.opacity(configuration.isPressed ? 0.16 : 0.09))
            .clipShape(Capsule())
    }
}

private struct TriggerStatusCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(AppTheme.green)
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Last hook event")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AppTheme.muted)
                    Text(model.lastEventSummary)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.lastActionSummary)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(2)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                TriggerLine(icon: "checkmark.circle.fill", text: "Triggers when Claude Code or Codex submits a prompt, starts a Bash/tool call, requests approval, or finishes work.", tone: .good)
                TriggerLine(icon: "sparkles", text: "Non-tool waits are covered: prompt submit starts AI generation, and Stop ends it.", tone: .good)
                TriggerLine(icon: "timer", text: "Overlay timing: \(model.overlayTimingDescription)", tone: .neutral)
                TriggerLine(icon: "terminal", text: "Long waits to try: sleep 12, pnpm test, npm run build, cargo test, xcodebuild, docker build.", tone: .neutral)
                TriggerLine(icon: "minus.circle.fill", text: "Manual Terminal commands are not watched yet; they need the future shell fallback integration.", tone: .warning)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.line, lineWidth: 1))
    }
}

private struct TriggerLine: View {
    let icon: String
    let text: String
    let tone: Tone

    var body: some View {
        Label {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(tone.color)
        }
    }
}

private struct IntegrationRow: View {
    @EnvironmentObject private var model: AppModel
    let integration: Integration
    let enabled: Bool
    let configured: Bool
    let hookSummary: String
    let note: String
    let isBusy: Bool
    let onChange: @Sendable (Bool) -> Void

    private var tone: Tone {
        if integration == .codex, configured, !model.codexTrustAcknowledged {
            return .warning
        }
        if configured { return .good }
        if enabled { return .warning }
        return .neutral
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: configured ? "checkmark.seal.fill" : (enabled ? "wrench.and.screwdriver.fill" : "circle"))
                        .foregroundStyle(tone.color)
                    Text(integration.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppTheme.ink)
                    StatusChip(text: hookSummary, tone: tone)
                }
                Text(integration.detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.muted)
                Text(note)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if integration == .codex, configured, !model.codexTrustAcknowledged {
                    Button {
                        model.setCodexTrustAcknowledged(true)
                        model.codexNote = "Ready."
                        model.codexHookSummary = "Ready"
                    } label: {
                        Label("I approved this in Codex", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(CompactButtonStyle(tone: .good))
                }
            }

            Spacer(minLength: 20)

            Toggle("", isOn: Binding(get: { enabled }, set: onChange))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(AppTheme.green)
                .disabled(isBusy)
        }
        .padding(16)
        .background(Color.white.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.line, lineWidth: 1))
    }
}

private struct TutorialView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Header(title: "Setup Tutorial", subtitle: "Enable Claude Code and Codex hooks, then approve the one Codex trust step.")
            TutorialStep(number: "1", title: "Put the app in Applications", text: "Keep WhileItThinks.app in /Applications before enabling hooks. Claude and Codex store an absolute path to the bundled hook binary.")
            TutorialStep(number: "2", title: "Turn on Claude Code", text: "The app merges hooks into ~/.claude/settings.json, preserves existing settings, and writes a timestamped backup. Claude Code CLI and the Claude Desktop Code tab both read user settings. No separate Claude trust step is required.")
            TutorialStep(number: "3", title: "Turn on Codex", text: "The app writes ~/.codex/hooks.json and leaves ~/.codex/config.toml alone. Then open Terminal, run codex, type /hooks in the Codex CLI, review WhileItThinks, and trust the command hooks once. Codex Desktop does not expose /hooks in chat.")
            TutorialStep(number: "4", title: "Allow notifications", text: "Notifications are only for completion and permission alerts. The daemon and hooks work without cloud services.")
            TutorialStep(number: "5", title: "Accessibility is optional", text: "Use it only for active-app/fullscreen suppression. Hook-based Claude and Codex detection does not require Accessibility.")
        }
    }
}

private struct PrivacyView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Header(title: "Privacy Defaults", subtitle: "The local event store is sanitized by default.")
            Bullet("No account, cloud sync, or remote event upload.")
            Bullet("No prompt text, assistant text, shell output, file contents, or raw command arguments are stored by default.")
            Bullet("Project paths, cwd, sessions, conversations, and generations are hashed before persistence.")
            Bullet("The hook exits successfully when the app is closed, so Claude Code and Codex are never blocked by WhileItThinks.")
        }
    }
}

private struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    private let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Diagnostics", subtitle: "Local smoke checks for the bundled daemon, hook, and installer.")

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                Button {
                    Task { await model.sendTestAiGenerationEvent() }
                } label: {
                    Label("AI Generate", systemImage: "sparkles")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(TonalButtonStyle(tone: .good))

                Button {
                    Task { await model.sendTestClaudeEvent() }
                } label: {
                    Label("Claude Shell", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(TonalButtonStyle(tone: .good))

                Button {
                    Task { await model.sendTestCodexEvent() }
                } label: {
                    Label("Codex Test", systemImage: "hammer.fill")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(TonalButtonStyle(tone: .good))

                Button {
                    Task { await model.sendTestPermissionEvent() }
                } label: {
                    Label("Permission", systemImage: "hand.raised.fill")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(TonalButtonStyle(tone: .good))

                Button {
                    Task { await model.refreshStatus() }
                } label: {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(TonalButtonStyle(tone: .neutral))
            }

            InfoBand(text: "Bundled hook path: \(model.hookPath)", systemImage: "terminal.fill", tone: .neutral, monospaced: true)
            TriggerStatusCard()

            VStack(alignment: .leading, spacing: 8) {
                Text("Last command output")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.muted)
                ScrollView {
                    Text(model.lastOutput.isEmpty ? "No output yet." : model.lastOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(minHeight: 170)
                .background(Color(red: 0.07, green: 0.09, blue: 0.09))
                .foregroundStyle(Color(red: 0.88, green: 0.93, blue: 0.89))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var launchAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                RaccoonBlinkingAvatar(size: 54)
                Header(title: "Settings", subtitle: "Local app controls.")
            }

            TimingSettingsCard()

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("App", subtitle: "Local startup and health controls.")
                Toggle("Launch WhileItThinks at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { value in
                        launchAtLogin = value
                        model.configureLaunchAtLogin(value)
                    }
                ))
                .tint(AppTheme.green)
                Text(model.launchAtLoginStatus)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.muted)
                Button("Refresh integration status") {
                    Task { await model.refreshAll() }
                }
                .buttonStyle(TonalButtonStyle(tone: .neutral))
            }

            Spacer()
        }
        .padding(20)
        .background(AppTheme.page)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct TimingSettingsCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Overlay Timing", subtitle: "Defaults for real AI/build waits, not a repeating timer.")
                    .layoutPriority(1)
                Spacer()
                Button("Reset Defaults") {
                    model.resetOverlayTimingDefaults()
                }
                .buttonStyle(TonalButtonStyle(tone: .neutral))
            }

            TimingStepper(
                title: "AI generation",
                detail: "Claude/Codex is composing without a tool call.",
                valueText: model.formattedDuration(model.aiOverlayDelaySeconds),
                value: Binding(
                    get: { model.aiOverlayDelaySeconds },
                    set: { model.setOverlayTiming(.aiDelay, seconds: $0) }
                ),
                range: OverlayTimingSetting.aiDelay.range,
                step: 1
            )

            TimingStepper(
                title: "Builds, tests, installs",
                detail: "Known long-running work: test, build, package install, Docker, Xcode.",
                valueText: model.formattedDuration(model.workOverlayDelaySeconds),
                value: Binding(
                    get: { model.workOverlayDelaySeconds },
                    set: { model.setOverlayTiming(.workDelay, seconds: $0) }
                ),
                range: OverlayTimingSetting.workDelay.range,
                step: 1
            )

            TimingStepper(
                title: "Generic shell commands",
                detail: "Lower-confidence commands like sleep, curl, gh, deploy CLIs.",
                valueText: model.formattedDuration(model.commandOverlayDelaySeconds),
                value: Binding(
                    get: { model.commandOverlayDelaySeconds },
                    set: { model.setOverlayTiming(.commandDelay, seconds: $0) }
                ),
                range: OverlayTimingSetting.commandDelay.range,
                step: 1
            )

            TimingStepper(
                title: "Overlay cooldown",
                detail: "Minimum time before another overlay can appear. Set to 0 to disable cooldown.",
                valueText: model.formattedDuration(model.overlayCooldownSeconds),
                value: Binding(
                    get: { model.overlayCooldownSeconds },
                    set: { model.setOverlayTiming(.cooldown, seconds: $0) }
                ),
                range: OverlayTimingSetting.cooldown.range,
                step: 15
            )

            InfoBand(text: "Current timing: \(model.overlayTimingDescription)", systemImage: "timer", tone: .neutral)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.line, lineWidth: 1))
    }
}

private struct TimingStepper: View {
    let title: String
    let detail: String
    let valueText: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppTheme.ink)
                    Text(detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(valueText)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.green)
                    .frame(minWidth: 54, alignment: .trailing)
            }
        }
    }
}

private struct Header: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(AppTheme.ink)
            Text(subtitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SectionTitle: View {
    let title: String
    let subtitle: String

    init(_ title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(AppTheme.ink)
            Text(subtitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.muted)
        }
    }
}

private struct InfoBand: View {
    let text: String
    let systemImage: String
    let tone: Tone
    var monospaced = false

    var body: some View {
        Label {
            if monospaced {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Text(text)
                    .font(.system(size: 13, weight: .medium))
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tone.color)
        }
        .foregroundStyle(AppTheme.ink)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.color.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tone.color.opacity(0.18), lineWidth: 1))
    }
}

private struct StatusChip: View {
    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(tone.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tone.color.opacity(0.11))
            .clipShape(Capsule())
    }
}

private struct TonalButtonStyle: ButtonStyle {
    let tone: Tone

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(tone == .good ? Color.white : AppTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(tone == .good ? tone.color.opacity(configuration.isPressed ? 0.78 : 1) : Color.white.opacity(configuration.isPressed ? 0.52 : 0.82))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tone == .good ? Color.clear : AppTheme.line, lineWidth: 1))
    }
}

private struct TutorialStep: View {
    let number: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 30, height: 30)
                .background(AppTheme.green)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppTheme.ink)
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.line, lineWidth: 1))
    }
}

private struct Bullet: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(AppTheme.ink)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.76))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.line, lineWidth: 1))
    }
}
