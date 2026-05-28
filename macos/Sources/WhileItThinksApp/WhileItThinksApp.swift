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
    case shell

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .shell: return "Terminal"
        }
    }

    var detail: String {
        switch self {
        case .claude:
            return "Covers Claude Code CLI and the Claude Desktop Code tab through shared user settings."
        case .codex:
            return "Covers Codex CLI and Codex Desktop after one-time hook approval from Codex CLI."
        case .shell:
            return "Optional. Watches commands you type in new zsh Terminal tabs."
        }
    }
}

private enum OverlayTimingDefaults {
    static let aiDelay = 6
    static let workDelay = 5
    static let commandDelay = 10
    static let cooldown = 240
}

private enum MicrobreakDefaults {
    static let blinkInterval = 600
}

private struct MicrobreakPrompt {
    let action: String
    let detail: String
    let systemImage: String
    let isBlink: Bool
}

private struct OverlayContent {
    let status: String
    let action: String
    let detail: String
    let systemImage: String
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
    @Published var shellInstalled = false
    @Published var claudeConfigured = false
    @Published var codexConfigured = false
    @Published var shellConfigured = false
    @Published var claudeNote = "Not checked yet."
    @Published var codexNote = "Not checked yet."
    @Published var shellNote = "Optional. Turn on if you want manual zsh Terminal commands to count as waits."
    @Published var claudeHookSummary = "Unknown"
    @Published var codexHookSummary = "Unknown"
    @Published var shellHookSummary = "Optional"
    @Published var daemonStatus = "Not running"
    @Published var daemonDetail = "Start the local receiver so hooks have somewhere to send events."
    @Published var daemonHelperInstalled = false
    @Published var daemonHelperConfigured = false
    @Published var daemonHelperHealthy = false
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
    @Published var cooldownRemainingSeconds = 0
    @Published var blinkPromptIntervalSeconds = MicrobreakDefaults.blinkInterval
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
    private var cooldownCountdownTask: Task<Void, Never>?
    private var nextMicrobreakIndex = 0
    private var lastBlinkPromptAt = Date.distantPast
    private let overlayPresenter = OverlayPresenter()

    init() {
        aiOverlayDelaySeconds = Self.storedTiming(for: .aiDelay)
        workOverlayDelaySeconds = Self.storedTiming(for: .workDelay)
        commandOverlayDelaySeconds = Self.storedTiming(for: .commandDelay)
        overlayCooldownSeconds = Self.storedTiming(for: .cooldown)
        blinkPromptIntervalSeconds = Self.storedBlinkPromptInterval()
        nextMicrobreakIndex = UserDefaults.standard.integer(forKey: "microbreak.nextPromptIndex")
        let lastBlink = UserDefaults.standard.double(forKey: "microbreak.lastBlinkPromptAt")
        if lastBlink > 0 {
            lastBlinkPromptAt = Date(timeIntervalSince1970: lastBlink)
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncAccessibilityStatus()
            }
        }
        startCooldownCountdown()
    }

    var bundleDirectory: URL {
        Bundle.main.bundleURL
    }

    var overlayTimingDescription: String {
        "AI thinking waits \(formattedPlainDuration(aiOverlayDelaySeconds)), builds/tests wait \(formattedPlainDuration(workOverlayDelaySeconds)), other commands wait \(formattedPlainDuration(commandOverlayDelaySeconds)), then cool down for \(formattedPlainDuration(overlayCooldownSeconds))."
    }

    var cooldownStatusText: String {
        guard cooldownRemainingSeconds > 0 else {
            return "Ready"
        }
        return "\(cooldownRemainingSeconds)s left"
    }

    var cooldownMenuTitle: String {
        "Cooldown: \(cooldownStatusText)"
    }

    var blinkPromptIntervalMinutes: Int {
        max(1, blinkPromptIntervalSeconds / 60)
    }

    var microbreakSummary: String {
        "\(Self.microbreakPrompts.count) rotating ideas. Blink prompts can appear at most once every \(formattedPlainDuration(blinkPromptIntervalSeconds))."
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

    var daemonPath: String {
        binaryURL("whileitthinksd").path
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

    private static func storedBlinkPromptInterval() -> Int {
        let key = "microbreak.blinkIntervalSeconds"
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return MicrobreakDefaults.blinkInterval
        }
        return min(max(UserDefaults.standard.integer(forKey: key), 60), 3600)
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

    func formattedPlainDuration(_ seconds: Int) -> String {
        if seconds == 0 {
            return "no time"
        }
        if seconds == 1 {
            return "1 second"
        }
        if seconds < 60 {
            return "\(seconds) seconds"
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if remainder == 0 {
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        let minuteText = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        let secondText = remainder == 1 ? "1 second" : "\(remainder) seconds"
        return "\(minuteText) \(secondText)"
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
                updateCooldownRemainingSeconds()
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

    func setBlinkPromptInterval(minutes: Int) {
        let seconds = min(max(minutes, 1), 60) * 60
        blinkPromptIntervalSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: "microbreak.blinkIntervalSeconds")
    }

    func resetMicrobreakDefaults() {
        setBlinkPromptInterval(minutes: MicrobreakDefaults.blinkInterval / 60)
        nextMicrobreakIndex = 0
        lastBlinkPromptAt = Date.distantPast
        UserDefaults.standard.set(nextMicrobreakIndex, forKey: "microbreak.nextPromptIndex")
        UserDefaults.standard.removeObject(forKey: "microbreak.lastBlinkPromptAt")
        lastActionSummary = "Microbreak prompts reset to recommended defaults."
    }

    private static let microbreakPrompts: [MicrobreakPrompt] = [
        MicrobreakPrompt(action: "Blink slowly 8 times", detail: "Close fully, open fully, and let your eyes reset.", systemImage: "sparkles", isBlink: true),
        MicrobreakPrompt(action: "Look 20 feet away", detail: "Pick one far object and keep your gaze soft for 20 seconds.", systemImage: "eye", isBlink: false),
        MicrobreakPrompt(action: "Roll your shoulders", detail: "Make 5 slow circles backward, then let them drop.", systemImage: "arrow.clockwise", isBlink: false),
        MicrobreakPrompt(action: "Stand up tall", detail: "Unfold your hips, stack your shoulders, and take one slow breath.", systemImage: "figure.stand", isBlink: false),
        MicrobreakPrompt(action: "Walk to the doorway", detail: "Take a tiny lap away from the screen and come back when it finishes.", systemImage: "figure.walk", isBlink: false),
        MicrobreakPrompt(action: "Close your eyes for 5 seconds", detail: "Let your eyelids rest. No peeking at the spinner.", systemImage: "moon.fill", isBlink: true),
        MicrobreakPrompt(action: "Stretch your fingers", detail: "Open both hands wide, then relax them into your lap.", systemImage: "hand.raised.fill", isBlink: false),
        MicrobreakPrompt(action: "Relax your jaw", detail: "Unclench your teeth and let your tongue rest.", systemImage: "face.smiling", isBlink: false),
        MicrobreakPrompt(action: "Take 3 slow breaths", detail: "In through the nose, out a little longer than the inhale.", systemImage: "wind", isBlink: false),
        MicrobreakPrompt(action: "Look out a window", detail: "Find daylight or the farthest edge of the room.", systemImage: "rectangle", isBlink: false),
        MicrobreakPrompt(action: "Do 10 calf raises", detail: "Stand if you can, lift your heels, and lower slowly.", systemImage: "arrow.up", isBlink: false),
        MicrobreakPrompt(action: "Rest your wrists", detail: "Let your hands drop from the keyboard for a moment.", systemImage: "keyboard", isBlink: false),
        MicrobreakPrompt(action: "Blink, then look far", detail: "Blink 5 times, then focus past the screen.", systemImage: "sparkles", isBlink: true),
        MicrobreakPrompt(action: "Turn your head gently", detail: "Look left, center, right, and back to center.", systemImage: "arrow.left.and.right", isBlink: false),
        MicrobreakPrompt(action: "Open your chest", detail: "Pull your shoulders back gently and breathe into the stretch.", systemImage: "figure.stand", isBlink: false),
        MicrobreakPrompt(action: "Shake out your arms", detail: "Loose wrists, loose elbows, no tension.", systemImage: "hand.raised.fill", isBlink: false),
        MicrobreakPrompt(action: "Check your posture", detail: "Feet down, shoulders low, screen at a comfortable height.", systemImage: "person.fill", isBlink: false),
        MicrobreakPrompt(action: "March in place", detail: "Stand and move for 20 seconds if you have room.", systemImage: "figure.walk", isBlink: false),
        MicrobreakPrompt(action: "Soften your gaze", detail: "Stop staring hard. Let the screen blur for a breath.", systemImage: "eye", isBlink: false),
        MicrobreakPrompt(action: "Sip water", detail: "Hydrate while the agent does the waiting.", systemImage: "drop.fill", isBlink: false),
        MicrobreakPrompt(action: "Stretch your neck gently", detail: "Ear toward shoulder, pause, then switch sides.", systemImage: "arrow.left.and.right", isBlink: false),
        MicrobreakPrompt(action: "Palms over eyes", detail: "Cover your closed eyes lightly for 10 seconds.", systemImage: "hand.raised.fill", isBlink: true),
        MicrobreakPrompt(action: "Ankle circles", detail: "Circle each ankle under the desk a few times.", systemImage: "circle", isBlink: false),
        MicrobreakPrompt(action: "Lean back and reset", detail: "Move your spine away from the screen and breathe.", systemImage: "arrow.up.left.and.arrow.down.right", isBlink: false),
        MicrobreakPrompt(action: "Focus far, then near", detail: "Far wall, then your hand, then far wall again.", systemImage: "scope", isBlink: false),
        MicrobreakPrompt(action: "Drop your shoulders", detail: "Lift them once, then let them fall heavy.", systemImage: "arrow.down", isBlink: false),
        MicrobreakPrompt(action: "Step away for 30 seconds", detail: "If this is a build or test, give your body a real pause.", systemImage: "figure.walk", isBlink: false),
        MicrobreakPrompt(action: "Relax your forehead", detail: "Smooth your brow and loosen your face.", systemImage: "face.smiling", isBlink: false),
        MicrobreakPrompt(action: "Reach overhead", detail: "Stretch up gently, then let your arms float down.", systemImage: "arrow.up", isBlink: false),
        MicrobreakPrompt(action: "Blink and breathe", detail: "Blink 6 times, then take one slow exhale.", systemImage: "sparkles", isBlink: true)
    ]

    private func cliBaseArguments() -> [String] {
        ["--hook-path", hookPath, "--daemon-path", daemonPath]
    }

    func refreshAll() async {
        startActionLogWatcher()
        startAccessibilityWatcher()
        await refreshStatus()
        await refreshNotificationStatus()
        syncAccessibilityStatus()
    }

    func refreshStatus() async {
        let result = await runCLI(cliBaseArguments() + ["status"])
        lastOutput = result.display
        guard result.exitCode == 0 else {
            claudeNote = "Could not read status."
            codexNote = result.display
            shellNote = result.display
            await refreshDaemonStatus()
            return
        }
        parseStatus(result.stdout)
    }

    func setIntegration(_ integration: Integration, enabled: Bool) async {
        isBusy = true
        defer { isBusy = false }

        let command = enabled ? "install" : "uninstall"
        let result = await runCLI(cliBaseArguments() + [command, integration.rawValue])
        lastOutput = result.display
        if integration == .codex {
            setCodexTrustAcknowledged(false)
        }
        await refreshStatus()
    }

    func ensureDaemonRunning() async {
        isDaemonStarting = true
        daemonStatus = "Checking"
        daemonDetail = "Checking whether the local receiver is accepting events."
        defer { isDaemonStarting = false }

        await refreshDaemonStatus()
        if daemonHelperConfigured && daemonHelperHealthy {
            return
        }

        if isRunningFromApplications {
            daemonStatus = "Starting"
            daemonDetail = "Installing the background receiver for this user account."
            let result = await runCLI(cliBaseArguments() + ["daemon", "install"])
            lastOutput = result.display
            if result.exitCode == 0 {
                parseDaemonStatus(result.stdout)
            } else {
                daemonStatus = "Needs attention"
                daemonDetail = result.display.isEmpty ? "Could not start the background receiver." : result.display
            }
            return
        }

        if daemonHelperHealthy {
            daemonStatus = "Running"
            return
        }
        if await daemonHealthCheck() {
            daemonStatus = "Running"
            return
        }

        await startDevDaemonFallback()
    }

    private func startDevDaemonFallback() async {
        let daemonURL = binaryURL("whileitthinksd")
        guard FileManager.default.isExecutableFile(atPath: daemonURL.path) else {
            daemonStatus = "Missing bundled daemon"
            daemonDetail = "Could not find whileitthinksd inside the app bundle."
            return
        }

        daemonStatus = "Starting"
        daemonDetail = "Launching bundled whileitthinksd for local development."

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
                daemonDetail = "Development receiver started. Install the app in /Applications for the background helper."
            } else {
                daemonStatus = "Starting"
                daemonDetail = "Receiver process launched, but the health check has not answered yet."
            }
        } catch {
            daemonStatus = "Failed to start: \(error.localizedDescription)"
            daemonDetail = "The bundled receiver could not be launched. Check Diagnostics for command output."
        }
    }

    func restartDaemonFromApp() async {
        isDaemonStarting = true
        daemonStatus = "Restarting"
        daemonDetail = "Restarting the local receiver."
        defer { isDaemonStarting = false }

        if isRunningFromApplications {
            let result = await runCLI(cliBaseArguments() + ["daemon", "restart"])
            lastOutput = result.display
            if result.exitCode == 0 {
                parseDaemonStatus(result.stdout)
            } else {
                daemonStatus = "Needs attention"
                daemonDetail = result.display.isEmpty ? "Could not restart the local receiver." : result.display
            }
        } else {
            daemonProcess?.terminate()
            daemonProcess = nil
            try? await Task.sleep(nanoseconds: 350_000_000)
            await startDevDaemonFallback()
        }
    }

    func refreshDaemonStatus() async {
        let result = await runCLI(cliBaseArguments() + ["daemon", "status"])
        guard result.exitCode == 0 else {
            daemonStatus = "Unknown"
            daemonDetail = result.display
            return
        }
        parseDaemonStatus(result.stdout)
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
        lastActionSummary = "Synthetic AI generation finished. Completion notifications are intentionally silent."
    }

    func sendTestPermissionEvent() async {
        await ensureDaemonRunning()
        let claude = await runCLI(["test-event", "--source", "claude-code", "--event", "permission_requested", "--command", ""])
        lastOutput = claude.display
        lastActionSummary = "Synthetic permission event sent. Approval alerts may use a system notification."
    }

    private func sendSyntheticShellEvent(source: String, label: String, command: String, simulatedSeconds: UInt64) async {
        await ensureDaemonRunning()
        lastActionSummary = "\(label) synthetic start sent. Waiting long enough to cross the overlay threshold."
        let start = await runCLI(["test-event", "--source", source, "--event", "shell_started", "--command", command])
        lastOutput = start.display
        try? await Task.sleep(nanoseconds: simulatedSeconds * 1_000_000_000)
        let finish = await runCLI(["test-event", "--source", source, "--event", "shell_finished", "--command", command])
        lastOutput = [start.display, finish.display].filter { !$0.isEmpty }.joined(separator: "\n")
        lastActionSummary = "\(label) synthetic finish sent. Completion notifications are intentionally silent."
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

    private func startCooldownCountdown() {
        guard cooldownCountdownTask == nil else { return }
        updateCooldownRemainingSeconds()
        cooldownCountdownTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateCooldownRemainingSeconds()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func updateCooldownRemainingSeconds(now: Date = Date()) {
        let remaining = max(0, Int(ceil(overlayCooldownUntil.timeIntervalSince(now))))
        if cooldownRemainingSeconds != remaining {
            cooldownRemainingSeconds = remaining
        }
    }

    private func parseStatus(_ output: String) {
        guard let data = output.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) else {
            claudeNote = output
            codexNote = output
            shellNote = output
            return
        }

        let items: [[String: Any]]
        if let object = decoded as? [String: Any] {
            items = object["integrations"] as? [[String: Any]] ?? []
            if let daemon = object["daemon"] as? [String: Any] {
                applyDaemonStatus(daemon)
            }
        } else if let array = decoded as? [[String: Any]] {
            items = array
        } else {
            claudeNote = output
            codexNote = output
            shellNote = output
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
            } else if integration == "shell" {
                shellInstalled = installed
                shellConfigured = item["configured"] as? Bool ?? false
                shellNote = integrationNextStep(.shell, item: item)
                shellHookSummary = hookSummary(item)
            }
        }
    }

    private func parseDaemonStatus(_ output: String) {
        guard let data = output.data(using: .utf8),
              let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            daemonStatus = "Unknown"
            daemonDetail = output
            return
        }
        applyDaemonStatus(item)
    }

    private func applyDaemonStatus(_ item: [String: Any]) {
        daemonHelperInstalled = item["installed"] as? Bool ?? false
        daemonHelperConfigured = item["configured"] as? Bool ?? false
        daemonHelperHealthy = item["healthy"] as? Bool ?? false
        let loaded = item["loaded"] as? Bool ?? false
        let note = item["note"] as? String ?? "Local receiver status unknown."

        if daemonHelperHealthy && daemonHelperConfigured {
            daemonStatus = "Running"
            daemonDetail = note
        } else if daemonHelperInstalled {
            daemonStatus = "Needs repair"
            daemonDetail = note
        } else if daemonHelperHealthy {
            daemonStatus = "Running"
            daemonDetail = note
        } else if daemonHelperConfigured && loaded {
            daemonStatus = "Starting"
            daemonDetail = note
        } else {
            daemonStatus = "Not installed"
            daemonDetail = note
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
        case .shell:
            return "Ready for new zsh Terminal tabs."
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
        if integration == "shell", !configured {
            return installed > 0 ? "Needs repair" : "Optional"
        }
        if integration == "shell", configured {
            return "Ready"
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
                    self.updateCooldownRemainingSeconds()
                    self.lastActionSummary = "Overlay suppressed by cooldown; \(self.cooldownStatusText.lowercased()). Event was still recorded."
                    return
                }
                self.visibleOverlayKey = key
                self.overlayCooldownUntil = Date().addingTimeInterval(TimeInterval(self.overlayCooldownSeconds))
                self.updateCooldownRemainingSeconds()
                self.overlayPresenter.show(content: self.overlayContent(for: waitState, fallback: message))
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

    private func overlayContent(for waitState: String, fallback: String) -> OverlayContent {
        let prompt = nextMicrobreakPrompt()
        return OverlayContent(
            status: overlayStatus(for: waitState, fallback: fallback),
            action: prompt.action,
            detail: prompt.detail,
            systemImage: prompt.systemImage
        )
    }

    private func overlayStatus(for waitState: String, fallback: String) -> String {
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

    private func nextMicrobreakPrompt() -> MicrobreakPrompt {
        guard !Self.microbreakPrompts.isEmpty else {
            return MicrobreakPrompt(
                action: "Look far away",
                detail: "Your code is busy. Let your eyes rest for a few seconds.",
                systemImage: "eye",
                isBlink: false
            )
        }

        for _ in Self.microbreakPrompts.indices {
            let index = nextMicrobreakIndex % Self.microbreakPrompts.count
            let prompt = Self.microbreakPrompts[index]
            nextMicrobreakIndex = (index + 1) % Self.microbreakPrompts.count
            UserDefaults.standard.set(nextMicrobreakIndex, forKey: "microbreak.nextPromptIndex")

            if prompt.isBlink && Date().timeIntervalSince(lastBlinkPromptAt) < TimeInterval(blinkPromptIntervalSeconds) {
                continue
            }
            if prompt.isBlink {
                lastBlinkPromptAt = Date()
                UserDefaults.standard.set(lastBlinkPromptAt.timeIntervalSince1970, forKey: "microbreak.lastBlinkPromptAt")
            }
            return prompt
        }

        return Self.microbreakPrompts.first { !$0.isBlink } ?? Self.microbreakPrompts[0]
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
    private let panelSize = NSSize(width: 410, height: 168)

    func show(content: OverlayContent) {
        if panel == nil {
            panel = makePanel()
        }
        let view = OverlayBanner(content: content) { [weak self] in
            self?.hide()
        }
        panel?.contentView = NSHostingView(rootView: view)
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
    let content: OverlayContent
    let onDismiss: () -> Void
    @State private var didEnter = false

    var body: some View {
        HStack(spacing: 14) {
            RaccoonBlinkingAvatar(size: 82)
                .offset(x: didEnter ? 0 : -18, y: didEnter ? 0 : 4)
                .opacity(didEnter ? 1 : 0)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The raccoon is on watch")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.green)
                        Text(content.status)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(1)
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

                Label {
                    Text(content.action)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: content.systemImage)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AppTheme.green)
                }

                Text(content.detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(2)

                HStack(spacing: 5) {
                    ForEach(0..<6, id: \.self) { index in
                        Capsule()
                            .fill(index < 3 ? AppTheme.green : Color(red: 0.74, green: 0.79, blue: 0.76))
                            .frame(width: index < 3 ? 20 : 9, height: 5)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 410, height: 168, alignment: .leading)
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
        Image(nsImage: MenuBarRaccoonTemplate.image)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 22, height: 22)
            .accessibilityLabel("WhileItThinks")
    }
}

private enum MenuBarRaccoonTemplate {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 26, height: 26))
        image.lockFocus()
        defer { image.unlockFocus() }

        let scale: CGFloat = 26 / 24
        func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
            NSRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
        }
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: x * scale, y: y * scale)
        }

        NSColor.black.setFill()

        let leftEar = NSBezierPath()
        leftEar.move(to: point(5.0, 16.0))
        leftEar.line(to: point(6.4, 22.6))
        leftEar.line(to: point(10.6, 18.4))
        leftEar.close()
        leftEar.fill()

        let rightEar = NSBezierPath()
        rightEar.move(to: point(19.0, 16.0))
        rightEar.line(to: point(17.6, 22.6))
        rightEar.line(to: point(13.4, 18.4))
        rightEar.close()
        rightEar.fill()

        NSBezierPath(roundedRect: rect(3.6, 3.1, 16.8, 17.4), xRadius: 8.4 * scale, yRadius: 8.7 * scale).fill()
        NSBezierPath(roundedRect: rect(5.0, 9.4, 14.0, 6.8), xRadius: 5.0 * scale, yRadius: 3.4 * scale).fill()

        guard let context = NSGraphicsContext.current?.cgContext else {
            image.isTemplate = true
            return image
        }

        context.setBlendMode(.clear)
        NSColor.clear.setFill()
        NSBezierPath(ovalIn: rect(7.2, 11.5, 3.2, 2.8)).fill()
        NSBezierPath(ovalIn: rect(13.6, 11.5, 3.2, 2.8)).fill()
        NSBezierPath(ovalIn: rect(8.2, 6.0, 7.6, 5.3)).fill()

        context.setLineCap(.round)
        context.setLineWidth(1.25 * scale)
        context.move(to: point(10.4, 17.6))
        context.addLine(to: point(9.0, 19.9))
        context.move(to: point(12.0, 17.8))
        context.addLine(to: point(12.0, 20.7))
        context.move(to: point(13.6, 17.6))
        context.addLine(to: point(15.0, 19.9))
        context.strokePath()

        context.setBlendMode(.normal)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect(10.25, 8.35, 3.5, 2.15), xRadius: 1.05 * scale, yRadius: 1.05 * scale).fill()

        NSColor.black.setStroke()
        let mouth = NSBezierPath()
        mouth.lineWidth = 0.9 * scale
        mouth.move(to: point(12.0, 8.2))
        mouth.line(to: point(12.0, 7.0))
        mouth.stroke()

        image.isTemplate = true
        return image
    }()
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

            SidebarStatus(title: "Receiver", value: model.daemonStatus, tone: model.daemonStatus.contains("Running") ? .good : .warning)
            SidebarStatus(title: "Cooldown", value: model.cooldownStatusText, tone: model.cooldownRemainingSeconds > 0 ? .warning : .good)

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
                if title == "Receiver" {
                    Button {
                        Task { await model.restartDaemonFromApp() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.green)
                    .disabled(model.isDaemonStarting)
                    .help("Restart receiver")
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
        Text(model.cooldownMenuTitle)
        Text("WhileItThinks")
        Text("Receiver: \(model.daemonStatus)")
        Text(model.daemonDetail)
            .font(.caption)
        Divider()
        Button("Open WhileItThinks") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button(model.daemonStatus.contains("Running") ? "Receiver Running" : "Start Receiver") {
            Task { await model.ensureDaemonRunning() }
        }
        .disabled(model.isDaemonStarting)
        Button("Restart Receiver") {
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
        VStack(alignment: .leading, spacing: 16) {
            HeroPanel()

            SectionTitle("Setup checklist", subtitle: "Turn on the pieces you need. Claude and Codex hooks are local, backed up, and reversible.")

            SetupChecklistRow(
                title: "App location",
                status: model.isRunningFromApplications ? "Ready" : "Move app",
                detail: model.installLocationMessage,
                systemImage: model.isRunningFromApplications ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                tone: model.isRunningFromApplications ? .good : .warning
            )

            SetupChecklistRow(
                title: "Local receiver",
                status: model.daemonStatus.contains("Running") ? "Ready" : "Start",
                detail: model.daemonDetail,
                systemImage: "antenna.radiowaves.left.and.right",
                tone: model.daemonStatus.contains("Running") ? .good : .warning,
                actionTitle: model.daemonStatus.contains("Running") ? "Restart" : "Start",
                actionIcon: "arrow.clockwise",
                disabled: model.isDaemonStarting
            ) {
                Task {
                    if model.daemonStatus.contains("Running") {
                        await model.restartDaemonFromApp()
                    } else {
                        await model.ensureDaemonRunning()
                    }
                }
            }

            SetupToggleChecklistRow(
                title: "Claude Code",
                status: model.claudeConfigured ? "Ready" : (model.claudeInstalled ? "Repair" : "Off"),
                detail: "Works for Claude Code CLI and the Claude Desktop Code tab through shared user settings.",
                note: model.claudeNote,
                systemImage: "sparkles",
                tone: model.claudeConfigured ? .good : (model.claudeInstalled ? .warning : .neutral),
                enabled: model.claudeInstalled,
                isBusy: model.isBusy
            ) { enabled in
                Task { await model.setIntegration(.claude, enabled: enabled) }
            }

            SetupToggleChecklistRow(
                title: "Codex",
                status: codexStatusText,
                detail: "Works for Codex CLI and Codex Desktop after you approve the hook once in Codex CLI.",
                note: model.codexNote,
                systemImage: "hammer.fill",
                tone: codexTone,
                enabled: model.codexInstalled,
                isBusy: model.isBusy,
                secondaryTitle: model.codexConfigured && !model.codexTrustAcknowledged ? "I approved it" : nil,
                secondaryIcon: "checkmark.circle.fill"
            ) { enabled in
                Task { await model.setIntegration(.codex, enabled: enabled) }
            } secondaryAction: {
                model.setCodexTrustAcknowledged(true)
                model.codexNote = "Ready."
                model.codexHookSummary = "Ready"
            }

            SetupToggleChecklistRow(
                title: "Terminal commands",
                status: model.shellConfigured ? "Ready" : (model.shellInstalled ? "Repair" : "Optional"),
                detail: "Optional. Watches commands you type in new zsh Terminal tabs.",
                note: model.shellNote,
                systemImage: "terminal.fill",
                tone: model.shellConfigured ? .good : (model.shellInstalled ? .warning : .neutral),
                enabled: model.shellInstalled,
                isBusy: model.isBusy
            ) { enabled in
                Task { await model.setIntegration(.shell, enabled: enabled) }
            }

            SetupChecklistRow(
                title: "Notifications",
                status: model.notificationStatus == "Enabled" ? "Ready" : "Optional",
                detail: "Used only for approval prompts that need attention. Finished commands stay silent.",
                systemImage: "bell.badge.fill",
                tone: model.notificationStatus == "Enabled" ? .good : .neutral,
                actionTitle: model.notificationStatus == "Enabled" ? nil : "Allow",
                actionIcon: "bell.badge.fill"
            ) {
                Task { await model.requestNotifications() }
            }

            TriggerStatusCard()
        }
    }

    private var codexStatusText: String {
        if model.codexConfigured && model.codexTrustAcknowledged { return "Ready" }
        if model.codexConfigured { return "Approve" }
        if model.codexInstalled { return "Repair" }
        return "Off"
    }

    private var codexTone: Tone {
        if model.codexConfigured && model.codexTrustAcknowledged { return .good }
        if model.codexConfigured || model.codexInstalled { return .warning }
        return .neutral
    }
}

private struct SetupChecklistRow: View {
    let title: String
    let status: String
    let detail: String
    let systemImage: String
    let tone: Tone
    var actionTitle: String? = nil
    var actionIcon: String? = nil
    var disabled = false
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(tone.color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AppTheme.ink)
                    StatusChip(text: status, tone: tone)
                }
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            if let actionTitle, let actionIcon, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: actionIcon)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(CompactButtonStyle(tone: tone))
                .disabled(disabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.line, lineWidth: 1))
    }
}

private struct SetupToggleChecklistRow: View {
    let title: String
    let status: String
    let detail: String
    let note: String
    let systemImage: String
    let tone: Tone
    let enabled: Bool
    let isBusy: Bool
    var secondaryTitle: String? = nil
    var secondaryIcon: String? = nil
    let onToggle: @Sendable (Bool) -> Void
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(tone.color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AppTheme.ink)
                    StatusChip(text: status, tone: tone)
                }
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(note)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.ink.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)

                if let secondaryTitle, let secondaryIcon, let secondaryAction {
                    Button(action: secondaryAction) {
                        Label(secondaryTitle, systemImage: secondaryIcon)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(CompactButtonStyle(tone: .good))
                }
            }

            Spacer(minLength: 16)

            Toggle("", isOn: Binding(get: { enabled }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(AppTheme.green)
                .disabled(isBusy)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.line, lineWidth: 1))
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
        PermissionStatusCard(
            title: "Notifications",
            value: model.notificationStatus,
            tone: model.notificationStatus == "Enabled" ? .good : .neutral,
            actionTitle: model.notificationStatus == "Enabled" ? nil : "Allow",
            actionIcon: "bell.badge.fill"
        ) {
            Task { await model.requestNotifications() }
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
                TriggerLine(icon: "timer", text: "Timing is a delay after a real wait starts: \(model.overlayTimingDescription)", tone: .neutral)
                TriggerLine(icon: "terminal", text: "Long waits to try: sleep 12, pnpm test, npm run build, cargo test, xcodebuild, docker build.", tone: .neutral)
                TriggerLine(
                    icon: model.shellConfigured ? "checkmark.circle.fill" : "plus.circle.fill",
                    text: model.shellConfigured ? "Manual zsh Terminal commands are watched in new tabs." : "Manual zsh Terminal commands are optional; turn on Terminal commands in Setup if you want them watched.",
                    tone: model.shellConfigured ? .good : .neutral
                )
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
            TutorialStep(number: "2", title: "Start the local receiver", text: "The receiver is a user-level background helper. Hooks send local events to it even when the main window is closed. The menu-bar app still needs to be open to draw overlays.")
            TutorialStep(number: "3", title: "Turn on Claude Code", text: "The app merges hooks into ~/.claude/settings.json, preserves existing settings, and writes a timestamped backup. Claude Code CLI and the Claude Desktop Code tab both read user settings. No separate Claude trust step is required.")
            TutorialStep(number: "4", title: "Turn on Codex", text: "The app writes ~/.codex/hooks.json and leaves ~/.codex/config.toml alone. Then open Terminal, run codex, type /hooks in the Codex CLI, review WhileItThinks, and trust the command hooks once. Codex Desktop does not expose /hooks in chat.")
            TutorialStep(number: "5", title: "Optional Terminal commands", text: "Turn on Terminal commands only if you want manually typed zsh commands to count as waits. Open a new Terminal tab after enabling it.")
            TutorialStep(number: "6", title: "Allow notifications", text: "Notifications are only for approval prompts that need your attention. Finished commands stay silent; the blink reminder is the overlay.")
            TutorialStep(number: "7", title: "Accessibility is not required", text: "Claude, Codex, Terminal command detection, and the background receiver work without Accessibility. Leave it off unless you want future active-app/fullscreen suppression controls in Settings.")
            TutorialStep(number: "8", title: "Leave timing alone at first", text: "The seconds in Settings are simple delays. If AI thinking is 6 seconds, the raccoon appears only when Claude or Codex is still working after 6 seconds. Fast replies do not show anything.")
            TutorialStep(number: "9", title: "Microbreaks rotate", text: "The overlay cycles through short ideas like looking far away, stretching, standing up, walking, breathing, and blinking. Blink-specific prompts are spaced out in Settings so they do not show every time.")
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    RaccoonBlinkingAvatar(size: 54)
                    Header(title: "Settings", subtitle: "Local app controls.")
                }

                TimingSettingsCard()
                MicrobreakSettingsCard()
                AdvancedSettingsCard()

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("App", subtitle: "Menu-bar startup and local receiver health.")
                    Toggle("Open WhileItThinks menu bar at login", isOn: Binding(
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
                    HStack(spacing: 10) {
                        Button("Refresh status") {
                            Task { await model.refreshAll() }
                        }
                        .buttonStyle(TonalButtonStyle(tone: .neutral))
                        Button(model.daemonStatus.contains("Running") ? "Restart receiver" : "Start receiver") {
                            Task {
                                if model.daemonStatus.contains("Running") {
                                    await model.restartDaemonFromApp()
                                } else {
                                    await model.ensureDaemonRunning()
                                }
                            }
                        }
                        .buttonStyle(TonalButtonStyle(tone: .neutral))
                        .disabled(model.isDaemonStarting)
                    }
                    Text("Receiver: \(model.daemonStatus). \(model.daemonDetail)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                SectionTitle("When should the overlay appear?", subtitle: "These are delays after real Claude/Codex wait states start. They are not repeating reminders.")
                    .layoutPriority(1)
                Spacer()
                Button {
                    model.resetOverlayTimingDefaults()
                } label: {
                    Text("Reset Defaults")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(TonalButtonStyle(tone: .neutral))
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            }

            TimingExplanationCard(aiDelayText: model.formattedPlainDuration(model.aiOverlayDelaySeconds))

            TimingStepper(
                title: "AI thinking delay",
                detail: "After you send a prompt, wait this long before showing the overlay. If Claude or Codex finishes sooner, nothing appears.",
                valueText: model.formattedPlainDuration(model.aiOverlayDelaySeconds),
                recommendedText: "Recommended: 6 seconds",
                value: Binding(
                    get: { model.aiOverlayDelaySeconds },
                    set: { model.setOverlayTiming(.aiDelay, seconds: $0) }
                ),
                range: OverlayTimingSetting.aiDelay.range,
                step: 1
            )

            TimingStepper(
                title: "Build/test delay",
                detail: "When an agent starts tests, builds, installs, Docker, or Xcode work, wait this long before nudging you to look away.",
                valueText: model.formattedPlainDuration(model.workOverlayDelaySeconds),
                recommendedText: "Recommended: 5 seconds",
                value: Binding(
                    get: { model.workOverlayDelaySeconds },
                    set: { model.setOverlayTiming(.workDelay, seconds: $0) }
                ),
                range: OverlayTimingSetting.workDelay.range,
                step: 1
            )

            TimingStepper(
                title: "Other command delay",
                detail: "For commands that might take a while but are less certain, wait longer before showing anything.",
                valueText: model.formattedPlainDuration(model.commandOverlayDelaySeconds),
                recommendedText: "Recommended: 10 seconds",
                value: Binding(
                    get: { model.commandOverlayDelaySeconds },
                    set: { model.setOverlayTiming(.commandDelay, seconds: $0) }
                ),
                range: OverlayTimingSetting.commandDelay.range,
                step: 1
            )

            TimingStepper(
                title: "Quiet time after an overlay",
                detail: "After the overlay appears once, wait this long before showing another one. This prevents back-to-back nudges.",
                valueText: model.formattedPlainDuration(model.overlayCooldownSeconds),
                recommendedText: "Recommended: 4 minutes",
                value: Binding(
                    get: { model.overlayCooldownSeconds },
                    set: { model.setOverlayTiming(.cooldown, seconds: $0) }
                ),
                range: OverlayTimingSetting.cooldown.range,
                step: 15
            )

            InfoBand(text: "Plain English: \(model.overlayTimingDescription)", systemImage: "timer", tone: .neutral)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.line, lineWidth: 1))
    }
}

private struct TimingExplanationCard: View {
    let aiDelayText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("What do these seconds mean?", systemImage: "questionmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppTheme.ink)
            Text("They are waiting periods. WhileItThinks only starts counting after Claude or Codex is already doing something that may take time.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("Most people should leave the defaults alone.")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AppTheme.green)
            Text("Example: if AI thinking is set to \(aiDelayText), a quick 3-second reply shows nothing. If the agent is still working after \(aiDelayText), the raccoon appears and closes when the work finishes.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.green.opacity(0.16), lineWidth: 1))
    }
}

private struct AdvancedSettingsCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Advanced", subtitle: "Optional controls that are not needed for Claude/Codex hooks.")

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(model.accessibilityStatus == "Granted" ? AppTheme.green : AppTheme.muted)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Accessibility permission")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppTheme.ink)
                    Text("Not required for setup. WhileItThinks only needs this later if you enable active-app or fullscreen suppression, such as avoiding overlays during calls or video.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Current status: \(model.accessibilityStatus)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(model.accessibilityStatus == "Granted" ? AppTheme.green : AppTheme.muted)
                }

                Spacer(minLength: 10)

                Button {
                    model.requestAccessibility()
                } label: {
                    Text("Open Settings")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(TonalButtonStyle(tone: .neutral))
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.line, lineWidth: 1))
    }
}

private struct MicrobreakSettingsCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("What should the raccoon suggest?", subtitle: "Each overlay rotates through small eye, posture, standing, walking, and stretch prompts.")
                    .layoutPriority(1)
                Spacer()
                Button {
                    model.resetMicrobreakDefaults()
                } label: {
                    Text("Reset")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(TonalButtonStyle(tone: .neutral))
                .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Microbreak rotation", systemImage: "shuffle")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppTheme.ink)
                Text(model.microbreakSummary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Blink prompts are useful, but annoying if they appear every time. This setting spaces out blink-specific prompts while other movement prompts keep rotating.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.green.opacity(0.16), lineWidth: 1))

            Stepper(value: Binding(
                get: { model.blinkPromptIntervalMinutes },
                set: { model.setBlinkPromptInterval(minutes: $0) }
            ), in: 1...60, step: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Blink prompt spacing")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(AppTheme.ink)
                        Text("Minimum time before another blink-specific suggestion can appear.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Recommended: 10 minutes")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AppTheme.green)
                    }
                    Spacer()
                    Text(model.formattedPlainDuration(model.blinkPromptIntervalSeconds))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AppTheme.green)
                        .frame(minWidth: 92, alignment: .trailing)
                }
            }
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
    let recommendedText: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppTheme.ink)
                    Text(detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(recommendedText)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppTheme.green)
                }
                Spacer()
                Text(valueText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppTheme.green)
                    .frame(minWidth: 92, alignment: .trailing)
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
