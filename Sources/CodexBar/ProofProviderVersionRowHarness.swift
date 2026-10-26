#if DEBUG
import AppKit
import CodexBarCore
import SwiftUI

/// FORK-ONLY PROOF HARNESS — not intended for upstream.
///
/// Dropped onto the `proof/4779-after` / `proof/4779-before` branches only, so CI can screenshot
/// the real Settings → provider card for Cursor and Raycast on both the PR head and its base commit.
/// Activation is file based: if `/tmp/codexbar-proof/` exists at launch, the harness runs and reads
/// `<dir>/provider` (`cursor` or `raycast`), opens Settings on that provider pane, waits for the real
/// `NSWindow`, records the production presentation values, and writes a marker JSON for the capture
/// job.
@MainActor
enum ProofProviderVersionRowHarness {
    static let defaultDirectory = "/tmp/codexbar-proof"

    static var isRequested: Bool {
        FileManager.default.fileExists(atPath: self.resolvedDirectory.path)
    }

    static var resolvedDirectory: URL {
        let path = ProcessInfo.processInfo.environment["CODEXBAR_PROOF_DIR"] ?? self.defaultDirectory
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func run(settings: SettingsStore, store: UsageStore, appDelegate: AppDelegate) {
        guard self.isRequested else { return }
        let directory = self.resolvedDirectory
        let rawProvider = (try? String(contentsOf: directory.appendingPathComponent("provider"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.log("harness enabled, directory=\(directory.path) provider=\(rawProvider)")
        guard let provider = UsageProvider(rawValue: rawProvider) else {
            self.writeMarker(
                directory: directory,
                provider: rawProvider.isEmpty ? "invalid" : rawProvider,
                payload: ["status": "invalid-provider", "providerArgument": rawProvider])
            return
        }

        settings.appLanguage = "en"
        settings.refreshFrequency = .manual
        // Make the card render like a configured provider rather than a disabled/unavailable row.
        settings.setProviderEnabled(
            provider: provider,
            metadata: store.metadata(for: provider),
            enabled: true)
        settings.providerEnablement[provider.instanceID] = true
        // The bug report describes a provider whose web usage kept refreshing successfully. This
        // credential-less runner cannot complete a real web fetch, so represent the production
        // post-success state by setting the last source label the card shows after a web refresh.
        store.lastSourceLabels[provider.instanceID] = "web"
        self.log("harness-set lastSourceLabel=web for \(provider.rawValue)")

        self.log("opening Settings on the \(provider.rawValue) provider pane")
        appDelegate.openSettings(pane: .provider(provider.instanceID))

        Task { @MainActor in
            await self.captureWhenReady(
                settings: settings,
                store: store,
                provider: provider,
                directory: directory,
                appDelegate: appDelegate)
        }
    }

    private static func captureWhenReady(
        settings: SettingsStore,
        store: UsageStore,
        provider: UsageProvider,
        directory: URL,
        appDelegate: AppDelegate) async
    {
        var window: NSWindow?
        let deadline = Date().addingTimeInterval(150)
        while Date() < deadline {
            if let candidate = appDelegate._proof_settingsWindow,
               candidate.isVisible,
               candidate.frame.width > 200
            {
                window = candidate
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let window else {
            self.log("timed out waiting for the Settings window")
            self.writeMarker(
                directory: directory,
                provider: provider.rawValue,
                payload: ["status": "window-timeout"])
            return
        }
        self.log("Settings window visible: number=\(window.windowNumber) frame=\(window.frame)")

        // Use a tall window so the provider header and the Source/Version info rows are in frame.
        if let screen = window.screen ?? NSScreen.main {
            let tallFrame = NSRect(
                x: screen.visibleFrame.origin.x + 8,
                y: screen.visibleFrame.maxY - 1200,
                width: max(1000, screen.visibleFrame.width - 16),
                height: 1200)
            window.setFrame(tallFrame, display: true)
            if window.frame.height < 900 {
                var visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
                visible.size.height = min(visible.height, 720)
                window.setFrame(visible, display: true)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(2500))

        // Production presentation values for this provider.
        let context = ProviderPresentationContext(
            provider: provider,
            settings: settings,
            store: store,
            metadata: store.metadata(for: provider))
        let implementation = ProviderCatalog.implementation(for: provider)
        let presentation = implementation?.presentation(context: context)
            ?? ProviderPresentation(detailLine: ProviderPresentation.standardDetailLine)
        let detailLine = presentation.detailLine(context)
        let showsVersionInSettings = presentation.showsVersionInSettings
        let versionText = ProviderDetailView<EmptyView>.versionText(provider: provider, store: store)
        let storedVersion = store.version(for: provider)
        let sourceLabel = store.sourceLabel(for: provider)
        let info = Bundle.main.infoDictionary ?? [:]
        let windowFrame: [Double] = [
            Double(window.frame.origin.x),
            Double(window.frame.origin.y),
            Double(window.frame.size.width),
            Double(window.frame.size.height),
        ]
        let payload: [String: Any] = [
            "status": "ready",
            "scenario": "provider-settings-version-row",
            "provider": provider.rawValue,
            "provider.displayName": store.metadata(for: provider).displayName,
            "presentation.detailLine": detailLine,
            "presentation.showsVersionInSettings": showsVersionInSettings,
            "presentation.versionTextIsNil": versionText == nil,
            "presentation.versionText": versionText ?? "nil",
            "store.version": storedVersion ?? "nil",
            "store.sourceLabel": sourceLabel,
            "sourceLabel.harnessInjected": true,
            "windowNumber": window.windowNumber,
            "windowTitle": window.title,
            "windowFrame": windowFrame,
            "windowIsVisible": window.isVisible,
            "windowServer": self.windowServerInfo(windowNumber: window.windowNumber),
            "app.version": info["CFBundleShortVersionString"] as? String ?? "",
            "app.build": info["CFBundleVersion"] as? String ?? "",
            "app.gitCommit": info["CodexGitCommit"] as? String ?? "",
            "app.bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "app.bundlePath": Bundle.main.bundlePath,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        let runtimeEvidence = [
            "provider=\(provider.rawValue) displayName=\(store.metadata(for: provider).displayName)",
            "presentation.detailLine=\(detailLine)",
            "presentation.showsVersionInSettings=\(showsVersionInSettings)",
            "presentation.versionText=\(versionText ?? "nil")",
            "store.version=\(storedVersion ?? "nil") store.sourceLabel=\(sourceLabel) "
                + "(lastSourceLabel harness-set to \"web\")",
            "window.number=\(window.windowNumber) window.frame=\(window.frame)",
            "app.version=\(info["CFBundleShortVersionString"] as? String ?? "") "
                + "app.gitCommit=\(info["CodexGitCommit"] as? String ?? "")",
        ]
        for line in runtimeEvidence {
            self.log(line)
        }
        do {
            try runtimeEvidence.joined(separator: "\n")
                .appending("\n")
                .write(
                    to: directory.appendingPathComponent("runtime-evidence-\(provider.rawValue).txt"),
                    atomically: true,
                    encoding: .utf8)
        } catch {
            self.log("failed to write runtime evidence: \(error)")
        }
        self.writeMarker(directory: directory, provider: provider.rawValue, payload: payload)
        self.log("marker written; keeping the Settings window on screen for capture")
    }

    private static func windowServerInfo(windowNumber: Int) -> [String: Any] {
        let list = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(windowNumber)) as? [[String: Any]] ?? []
        guard let info = list.first else { return ["found": false] }
        return [
            "found": true,
            "ownerName": info[kCGWindowOwnerName as String] as? String ?? "",
            "number": info[kCGWindowNumber as String] as? Int ?? -1,
            "layer": info[kCGWindowLayer as String] as? Int ?? -1,
            "onscreen": info[kCGWindowIsOnscreen as String] as? Bool ?? false,
            "alpha": info[kCGWindowAlpha as String] as? Double ?? -1,
            "bounds": String(describing: info[kCGWindowBounds as String] ?? ""),
        ]
    }

    private static func writeMarker(directory: URL, provider: String, payload: [String: Any]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys])
            try data.write(
                to: directory.appendingPathComponent("marker-provider-\(provider).json"),
                options: [.atomic])
            try data.write(to: directory.appendingPathComponent("marker.json"), options: [.atomic])
            self.log("wrote marker \(directory.appendingPathComponent("marker-provider-\(provider).json").path)")
        } catch {
            self.log("failed to write marker: \(error)")
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardOutput.write(Data("[proof-harness] \(message)\n".utf8))
    }
}
#endif
