#if DEBUG
import AppKit
import CodexBarCore
import SwiftUI

/// FORK-ONLY PROOF HARNESS — not intended for upstream.
///
/// Dropped onto the `proof/4780-compat` branch only, so CI can prove upgrade/data-model
/// compatibility for PR #4780 / issue #4764: a v0.81.0-style stored settings file that hides the
/// detail section through the legacy `detailSection:Credits` id must keep working after restart on
/// the PR-head build, now hiding the renamed `detailSection:Credit breakdown` row without spawning an
/// unavailable placeholder row.
///
/// Two launches share one proof directory:
/// - `mode=seed`: writes the legacy hidden id through the production settings/config API, then keeps
///   the app alive while the workflow waits for the config file to contain the legacy id.
/// - `mode=verify`: a fresh process reads the persisted pre-upgrade config; the harness does NOT
///   rewrite it, injects a Trae CN usage snapshot through the existing DEBUG store hook (no
///   credentials are available on the runner), opens the real Settings → Trae CN pane, and records
///   the raw stored ids, migrated/resolved hidden ids, picker rows and window state.
@MainActor
enum ProofTraeCNCompatHarness {
    static let defaultDirectory = "/tmp/codexbar-proof"
    static let legacyHiddenID = "detailSection:Credits"
    static let migratedHiddenID = "detailSection:Credit breakdown"

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
        let mode = (try? String(contentsOf: directory.appendingPathComponent("mode"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "verify"
        self.log("harness enabled, directory=\(directory.path) mode=\(mode)")

        settings.appLanguage = "en"
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.providerEnablement[UsageProvider.traecn.instanceID] = true
        settings.setProviderEnabled(
            provider: .traecn,
            metadata: store.metadata(for: .traecn),
            enabled: true)

        let instanceID = UsageProvider.traecn.instanceID
        let rawStoredHiddenIDs = settings.pluginConfig(instanceID)?.hiddenUsageItemIDs ?? []
        let resolvedHiddenIDs = settings.hiddenUsageItemIDs(for: .traecn)

        if mode == "seed" {
            // Write the pre-upgrade (v0.81.0-style) stored choice through the production config API.
            settings.updateProviderConfig(provider: .traecn) { entry in
                entry.hiddenUsageItemIDs = [Self.legacyHiddenID]
            }
            let written = settings.pluginConfig(instanceID)?.hiddenUsageItemIDs ?? []
            let resolvedAfterWrite = settings.hiddenUsageItemIDs(for: .traecn)
            self.log("seed: wrote legacy hidden id \(self.legacyHiddenID); "
                + "config now holds \(written) resolved=\(resolvedAfterWrite.map(\.rawValue))")
            self.writeMarker(
                directory: directory,
                name: "seed",
                payload: [
                    "status": "seeded",
                    "mode": "seed",
                    "legacyHiddenID": self.legacyHiddenID,
                    "config.hiddenUsageItemIDs": written,
                    "resolvedHiddenIDs": resolvedAfterWrite.map(\.rawValue).sorted(),
                    "app.gitCommit": Bundle.main.object(forInfoDictionaryKey: "CodexGitCommit") as? String ?? "",
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                ])
            return
        }

        // Verify launch: do not touch the persisted config; only read through the production API.
        self.log("verify: raw config hidden ids=\(rawStoredHiddenIDs) "
            + "resolved hidden ids=\(resolvedHiddenIDs.map(\.rawValue))")
        self.log("opening Settings on the Trae CN provider pane")
        appDelegate.openSettings(pane: .provider(instanceID))

        Task { @MainActor in
            await self.verifyWhenReady(
                settings: settings,
                store: store,
                rawStoredHiddenIDs: rawStoredHiddenIDs,
                resolvedHiddenIDs: resolvedHiddenIDs,
                directory: directory,
                appDelegate: appDelegate)
        }
    }

    private static func verifyWhenReady(
        settings: SettingsStore,
        store: UsageStore,
        rawStoredHiddenIDs: [String],
        resolvedHiddenIDs: Set<ProviderUsageItemID>,
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
            self.writeMarker(directory: directory, name: "verify", payload: ["status": "window-timeout"])
            return
        }
        self.log("Settings window visible: number=\(window.windowNumber) frame=\(window.frame)")
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

        // Inject a Trae CN usage snapshot so the detail-section visibility row exists in the picker.
        let section = try? ProviderDetailSection(
            title: "Credit breakdown",
            rows: [
                try? ProviderDetailSection.Row(label: "Used", value: "30"),
                try? ProviderDetailSection.Row(label: "Total", value: "100"),
                try? ProviderDetailSection.Row(label: "Remaining", value: "70"),
            ].compactMap { $0 })
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 30,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            details: [section].compactMap { $0 },
            updatedAt: Date())
        store._setSnapshotForTesting(snapshot, provider: .traecn)
        try? await Task.sleep(for: .milliseconds(800))

        let input = store.menuCardInput(
            for: .traecn,
            context: .settings,
            optionalUsageOverride: true)
        let model = UsageMenuCardView.Model.make(input)
        let items = model.usageItemDescriptors(
            includingHidden: settings.hiddenUsageItemIDs(for: .traecn),
            hidePersonalInfo: settings.hidePersonalInfo)
        let itemRows: [[String: Any]] = items.map { item in
            [
                "id": item.id.rawValue,
                "title": item.title,
                "isVisible": settings.isUsageItemVisible(item.id, for: .traecn),
            ]
        }
        let itemIDs = items.map(\.id.rawValue)
        let hasLegacyRow = itemIDs.contains(Self.legacyHiddenID)
        let hasUnavailableRow = items.contains { $0.title.contains("(unavailable)") }
            || items.contains { $0.id.rawValue.contains(Self.legacyHiddenID) }
        let detailRow = items.first { $0.id == ProviderUsageItemID.detailSection("Credit breakdown") }
        let info = Bundle.main.infoDictionary ?? [:]
        let windowFrame: [Double] = [
            Double(window.frame.origin.x),
            Double(window.frame.origin.y),
            Double(window.frame.size.width),
            Double(window.frame.size.height),
        ]
        let payload: [String: Any] = [
            "status": "ready",
            "scenario": "traecn-legacy-hidden-detail-section-compat",
            "mode": "verify",
            "legacyHiddenID": Self.legacyHiddenID,
            "migratedHiddenID": Self.migratedHiddenID,
            "config.hiddenUsageItemIDs": rawStoredHiddenIDs,
            "resolvedHiddenIDs": resolvedHiddenIDs.map(\.rawValue).sorted(),
            "picker.items": itemRows,
            "picker.itemIDs": itemIDs,
            "picker.itemTitles": items.map(\.title),
            "migratedDetailRow.isVisible": detailRow.map {
                settings.isUsageItemVisible($0.id, for: .traecn)
            } ?? false,
            "migratedDetailRow.present": detailRow != nil,
            "hasLegacyRow": hasLegacyRow,
            "hasUnavailablePlaceholderRow": hasUnavailableRow,
            "snapshot.present": store.snapshot(for: UsageProvider.traecn.instanceID) != nil,
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
            "mode=verify",
            "config.hiddenUsageItemIDs=\(rawStoredHiddenIDs)",
            "resolvedHiddenIDs=\(resolvedHiddenIDs.map(\.rawValue).sorted())",
            "picker.itemIDs=\(itemIDs)",
            "picker.itemTitles=\(items.map(\.title))",
            "migratedDetailRow.present=\(detailRow != nil) "
                + "migratedDetailRow.isVisible=\(detailRow.map { settings.isUsageItemVisible($0.id, for: .traecn) } ?? false)",
            "hasLegacyRow=\(hasLegacyRow) hasUnavailablePlaceholderRow=\(hasUnavailableRow)",
            "window.number=\(window.windowNumber)",
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
                    to: directory.appendingPathComponent("runtime-evidence-verify.txt"),
                    atomically: true,
                    encoding: .utf8)
        } catch {
            self.log("failed to write runtime evidence: \(error)")
        }
        self.writeMarker(directory: directory, name: "verify", payload: payload)
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

    private static func writeMarker(directory: URL, name: String, payload: [String: Any]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys])
            try data.write(
                to: directory.appendingPathComponent("marker-\(name).json"),
                options: [.atomic])
            try data.write(to: directory.appendingPathComponent("marker.json"), options: [.atomic])
            self.log("wrote marker \(directory.appendingPathComponent("marker-\(name).json").path)")
        } catch {
            self.log("failed to write marker: \(error)")
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardOutput.write(Data("[proof-harness] \(message)\n".utf8))
    }
}
#endif
