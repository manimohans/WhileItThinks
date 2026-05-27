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
                .frame(width: 520, height: 360)
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
            return "Covers Claude Code CLI and the Claude Desktop Code tab through user settings."
        case .codex:
            return "Covers Codex CLI and Codex Desktop after one-time hook approval from Codex CLI."
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
    @Published var accessibilityStatus = AXIsProcessTrusted() ? "Enabled" : "Optional, not enabled"
    @Published var launchAtLoginStatus = "Not configured"
    @Published var lastOutput = ""
    @Published var isBusy = false
    @Published var isDaemonStarting = false

    private var daemonProcess: Process?
    private var daemonOutputBuffer = ""
    private var actionLogOffset: UInt64 = 0
    private var actionLogWatcher: Task<Void, Never>?
    private var accessibilityWatcher: Task<Void, Never>?
    private var seenActionIDs = Set<String>()
    private let overlayPresenter = OverlayPresenter()

    var bundleDirectory: URL {
        Bundle.main.bundleURL
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
        accessibilityStatus = trusted ? "Enabled" : "Waiting for System Settings approval"
        startAccessibilityWatcher()
        openAccessibilitySettings()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
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
        await ensureDaemonRunning()
        overlayPresenter.show(message: "Claude test is thinking")
        let start = await runCLI(["test-event", "--source", "claude-code", "--event", "PreToolUse", "--command", "sleep 8"])
        lastOutput = start.display
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let finish = await runCLI(["test-event", "--source", "claude-code", "--event", "PostToolUse", "--command", "sleep 8"])
        lastOutput = [start.display, finish.display].filter { !$0.isEmpty }.joined(separator: "\n")
        overlayPresenter.hide()
        postNotification(title: "WhileItThinks test", body: "Claude test completed.")
    }

    func sendTestCodexEvent() async {
        await ensureDaemonRunning()
        overlayPresenter.show(message: "Codex test is thinking")
        let start = await runCLI(["test-event", "--source", "codex", "--event", "PreToolUse", "--command", "pnpm test"])
        lastOutput = start.display
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let finish = await runCLI(["test-event", "--source", "codex", "--event", "PostToolUse", "--command", "pnpm test"])
        lastOutput = [start.display, finish.display].filter { !$0.isEmpty }.joined(separator: "\n")
        overlayPresenter.hide()
        postNotification(title: "WhileItThinks test", body: "Codex test completed.")
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
        accessibilityStatus = AXIsProcessTrusted() ? "Enabled" : "Optional, not enabled"
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
            let note = item["note"] as? String ?? ""
            if integration == "claude" {
                claudeInstalled = installed
                claudeConfigured = item["configured"] as? Bool ?? false
                claudeNote = note
                claudeHookSummary = hookSummary(item)
            } else if integration == "codex" {
                codexInstalled = installed
                codexConfigured = item["configured"] as? Bool ?? false
                codexNote = note
                codexHookSummary = hookSummary(item)
            }
        }
    }

    private func hookSummary(_ item: [String: Any]) -> String {
        let installed = item["installed_hook_count"] as? Int ?? 0
        let expected = item["expected_hook_count"] as? Int ?? 0
        let configured = item["configured"] as? Bool ?? false
        let pathExists = item["expected_hook_path_exists"] as? Bool ?? false
        let stalePaths = item["stale_hook_paths"] as? [String] ?? []
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
        lastOutput = line

        if kind == "started" {
            overlayPresenter.show(message: message)
        } else if kind == "finished" {
            overlayPresenter.hide()
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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setup: return "Setup"
        case .tutorial: return "Tutorial"
        case .privacy: return "Privacy"
        case .diagnostics: return "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .setup: return "switch.2"
        case .tutorial: return "list.bullet.rectangle"
        case .privacy: return "lock.shield"
        case .diagnostics: return "waveform.path.ecg"
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

    private let grid = [
        GridItem(.adaptive(minimum: 178), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeroPanel()

            LazyVGrid(columns: grid, spacing: 12) {
                StatusPill(title: "Daemon", value: model.daemonStatus, tone: model.daemonStatus.contains("Running") ? .good : .warning)
                StatusPill(title: "Notifications", value: model.notificationStatus, tone: model.notificationStatus == "Enabled" ? .good : .neutral)
                StatusPill(title: "Accessibility", value: model.accessibilityStatus, tone: model.accessibilityStatus == "Enabled" ? .good : .neutral)
            }

            InfoBand(text: model.installLocationMessage, systemImage: model.isRunningFromApplications ? "checkmark.seal.fill" : "exclamationmark.triangle.fill", tone: model.isRunningFromApplications ? .good : .warning)
            InfoBand(text: model.daemonDetail, systemImage: model.daemonStatus.contains("Running") ? "checkmark.circle.fill" : "info.circle.fill", tone: model.daemonStatus.contains("Running") ? .good : .neutral)

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

            ActionBar()
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

private struct ActionBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.ensureDaemonRunning() }
            } label: {
                Label(model.daemonStatus.contains("Running") ? "Daemon Running" : (model.isDaemonStarting ? "Starting..." : "Start Daemon"), systemImage: model.daemonStatus.contains("Running") ? "checkmark.circle.fill" : "bolt.circle.fill")
            }
            .buttonStyle(TonalButtonStyle(tone: .good))
            .disabled(model.isDaemonStarting)

            Button {
                Task { await model.restartDaemonFromApp() }
            } label: {
                Label("Restart", systemImage: "arrow.clockwise.circle.fill")
            }
            .buttonStyle(TonalButtonStyle(tone: .neutral))
            .disabled(model.isDaemonStarting)

            Button {
                Task { await model.requestNotifications() }
            } label: {
                Label("Notifications", systemImage: "bell.badge.fill")
            }
            .buttonStyle(TonalButtonStyle(tone: .neutral))

            Button {
                model.requestAccessibility()
            } label: {
                Label(model.accessibilityStatus == "Enabled" ? "Accessibility On" : "Open Accessibility", systemImage: "hand.raised.fill")
            }
            .buttonStyle(TonalButtonStyle(tone: model.accessibilityStatus == "Enabled" ? .good : .warning))

            Button {
                Task { await model.refreshAll() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(TonalButtonStyle(tone: .neutral))
        }
        .padding(.top, 2)
    }
}

private struct IntegrationRow: View {
    let integration: Integration
    let enabled: Bool
    let configured: Bool
    let hookSummary: String
    let note: String
    let isBusy: Bool
    let onChange: @Sendable (Bool) -> Void

    private var tone: Tone {
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
            TutorialStep(number: "2", title: "Turn on Claude Code", text: "The app merges hooks into ~/.claude/settings.json, preserves existing settings, and writes a timestamped backup. Claude Code CLI and the Claude Desktop Code tab both read user settings.")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Diagnostics", subtitle: "Local smoke checks for the bundled daemon, hook, and installer.")

            HStack(spacing: 10) {
                Button {
                    Task { await model.sendTestClaudeEvent() }
                } label: {
                    Label("Send Claude Test", systemImage: "paperplane.fill")
                }
                .buttonStyle(TonalButtonStyle(tone: .good))

                Button {
                    Task { await model.sendTestCodexEvent() }
                } label: {
                    Label("Send Codex Test", systemImage: "paperplane.fill")
                }
                .buttonStyle(TonalButtonStyle(tone: .good))

                Button {
                    Task { await model.refreshStatus() }
                } label: {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                }
                .buttonStyle(TonalButtonStyle(tone: .neutral))
            }

            InfoBand(text: "Bundled hook path: \(model.hookPath)", systemImage: "terminal.fill", tone: .neutral, monospaced: true)

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
            Toggle("Launch WhileItThinks at login", isOn: Binding(
                get: { launchAtLogin },
                set: { value in
                    launchAtLogin = value
                    model.configureLaunchAtLogin(value)
                }
            ))
            .tint(AppTheme.green)
            Text(model.launchAtLoginStatus)
                .foregroundStyle(AppTheme.muted)
            Button("Refresh integration status") {
                Task { await model.refreshAll() }
            }
            .buttonStyle(TonalButtonStyle(tone: .neutral))
            Spacer()
        }
        .padding(20)
        .background(AppTheme.page)
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

private struct StatusPill: View {
    let title: String
    let value: String
    let tone: Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(tone.color)
                    .frame(width: 8, height: 8)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppTheme.muted)
            }
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.86)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .background(Color.white.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.line, lineWidth: 1))
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
