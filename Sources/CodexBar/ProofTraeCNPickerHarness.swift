#if DEBUG
import AppKit
import CodexBarCore
import SwiftUI

/// FORK-ONLY PROOF HARNESS — not intended for upstream.
///
/// Dropped onto the `proof/4780-after` / `proof/4780-before` branches only, so CI can screenshot
/// the real Settings → Trae CN pane with the "Visible usage items" picker. Activation is file based:
/// if `/tmp/codexbar-proof/` exists at launch, the harness runs; `<dir>/mode` is `after` or `before`
/// and selects the Credit-breakdown detail-section title that the corresponding build's plugin emits.
/// A Trae CN usage snapshot is injected through the existing DEBUG `UsageStore` state hook (no
/// credentials are available on the runner), and the harness reports the production picker item
/// descriptors plus hidden-ID migration state in marker JSON for the capture job.
@MainActor
enum ProofTraeCNPickerHarness {
    static let defaultDirectory = "/tmp/codexbar-proof"
    static let stepCount = 3

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
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "after"
        let detailTitle = mode == "before" ? "Credits" : "Credit breakdown"
        self.log("harness enabled, directory=\(directory.path) mode=\(mode) detailTitle=\(detailTitle)")

        settings.appLanguage = "en"
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setProviderEnabled(
            provider: .traecn,
            metadata: store.metadata(for: .traecn),
            enabled: true)
        settings.providerEnablement[UsageProvider.traecn.instanceID] = true

        // Hidden-ID migration evidence: store the legacy Trae CN detail-section id, then read the
        // effective hidden set through the production settings API (the PR migrates it on read).
        settings.updateProviderConfig(provider: .traecn) { entry in
            entry.hiddenUsageItemIDs = ["detailSection:Credits"]
        }
        let migratedHiddenIDs = settings.hiddenUsageItemIDs(for: .traecn)
        self.log("hidden-ID migration: stored=detailSection:Credits resolved=\(migratedHiddenIDs)")

        self.log("opening Settings on the Trae CN provider pane")
        appDelegate.openSettings(pane: .provider(UsageProvider.traecn.instanceID))

        Task { @MainActor in
            await self.captureSequence(
                settings: settings,
                store: store,
                detailTitle: detailTitle,
                migratedHiddenIDs: migratedHiddenIDs,
                directory: directory,
                appDelegate: appDelegate)
        }
    }

    private static func captureSequence(
        settings: SettingsStore,
        store: UsageStore,
        detailTitle: String,
        migratedHiddenIDs: Set<ProviderUsageItemID>,
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
                step: 0,
                payload: ["status": "window-timeout", "detailTitle": detailTitle])
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

        let detail = self.detailScrollView(in: window)
        let maxOffset = self.maximumScrollOffset(for: detail)
        let offsets: [CGFloat] = [0, 260, 520]
        let ackPath = directory.appendingPathComponent("next").path

        for step in 0..<self.stepCount {
            if step > 0 {
                self.applyScroll(detail, offset: min(offsets[step], maxOffset))
                try? await Task.sleep(for: .milliseconds(900))
            }
            // Re-assert the injected snapshot in case a background Trae CN refresh raced it.
            let snapshot = self.seedSnapshot(store: store, detailTitle: detailTitle)
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
                    "requiresOptionalUsage": item.requiresOptionalUsage,
                    "isVisible": settings.isUsageItemVisible(item.id, for: .traecn),
                ]
            }
            let info = Bundle.main.infoDictionary ?? [:]
            let windowFrame: [Double] = [
                Double(window.frame.origin.x),
                Double(window.frame.origin.y),
                Double(window.frame.size.width),
                Double(window.frame.size.height),
            ]
            let payload: [String: Any] = [
                "status": "ready",
                "scenario": "traecn-visible-usage-items-picker",
                "mode": detailTitle == "Credits" ? "before" : "after",
                "step": step,
                "stepCount": self.stepCount,
                "scrollOffset": Double(step > 0 ? min(offsets[step], maxOffset) : 0),
                "scrollMaxOffset": Double(maxOffset),
                "provider": "traecn",
                "provider.displayName": store.metadata(for: .traecn).displayName,
                "snapshot.present": store.snapshot(for: UsageProvider.traecn.instanceID) != nil,
                "snapshot.primaryUsedPercent": snapshot.primary?.usedPercent ?? -1,
                "snapshot.detailsTitles": snapshot.details.compactMap(\.title),
                "snapshot.detailRowLabels": snapshot.details.flatMap { $0.rows.map(\.label) },
                "picker.items": itemRows,
                "picker.itemIDs": items.map(\.id.rawValue),
                "picker.itemTitles": items.map(\.title),
                "picker.hasCustomVisibility": settings.hasCustomUsageItemVisibility(for: .traecn),
                "hiddenIDs.migrated": migratedHiddenIDs.map(\.rawValue).sorted(),
                "hiddenIDs.afterClear": settings.hiddenUsageItemIDs(for: .traecn).map(\.rawValue).sorted(),
                "model.metrics": model.metrics.map(\.title),
                "model.providerDetailRawTitles": model.providerDetailRawTitles.compactMap { $0 },
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
                "mode=\(detailTitle == "Credits" ? "before" : "after") step=\(step) "
                    + "scroll=\(step > 0 ? min(offsets[step], maxOffset) : 0)",
                "provider=traecn snapshot.present=true detailsTitles=\(snapshot.details.compactMap(\.title))",
                "picker.itemIDs=\(items.map(\.id.rawValue))",
                "picker.itemTitles=\(items.map(\.title))",
                "picker.hasCustomVisibility=\(settings.hasCustomUsageItemVisibility(for: .traecn))",
                "hiddenIDs.migrated=\(migratedHiddenIDs.map(\.rawValue).sorted())",
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
                        to: directory.appendingPathComponent("runtime-evidence-step\(step).txt"),
                        atomically: true,
                        encoding: .utf8)
            } catch {
                self.log("failed to write runtime evidence: \(error)")
            }
            self.writeMarker(directory: directory, step: step, payload: payload)

            guard step < self.stepCount - 1 else { break }
            let ackDeadline = Date().addingTimeInterval(90)
            while Date() < ackDeadline {
                if FileManager.default.fileExists(atPath: ackPath) {
                    try? FileManager.default.removeItem(atPath: ackPath)
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        self.log("capture sequence complete")
    }

    @discardableResult
    private static func seedSnapshot(store: UsageStore, detailTitle: String) -> UsageSnapshot {
        let section = try? ProviderDetailSection(
            title: detailTitle,
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
        return snapshot
    }

    private static func detailScrollView(in window: NSWindow) -> NSScrollView? {
        self.allScrollViews(in: window.contentView)
            .max(by: { $0.contentView.bounds.width < $1.contentView.bounds.width })
    }

    private static func allScrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        var found: [NSScrollView] = []
        if let scrollView = view as? NSScrollView {
            found.append(scrollView)
        }
        for subview in view.subviews {
            found.append(contentsOf: self.allScrollViews(in: subview))
        }
        return found
    }

    private static func maximumScrollOffset(for scrollView: NSScrollView?) -> CGFloat {
        guard let scrollView, let documentView = scrollView.documentView else { return 0 }
        return max(0, documentView.frame.height - scrollView.contentView.bounds.height)
    }

    private static func applyScroll(_ scrollView: NSScrollView?, offset: CGFloat) {
        guard let scrollView else { return }
        let point = NSPoint(x: scrollView.contentView.bounds.origin.x, y: offset)
        scrollView.contentView.scroll(to: point)
        scrollView.reflectScrolledClipView(scrollView.contentView)
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

    private static func writeMarker(directory: URL, step: Int, payload: [String: Any]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys])
            try data.write(
                to: directory.appendingPathComponent("marker-step\(step).json"),
                options: [.atomic])
            try data.write(to: directory.appendingPathComponent("marker.json"), options: [.atomic])
            self.log("wrote marker \(directory.appendingPathComponent("marker-step\(step).json").path)")
        } catch {
            self.log("failed to write marker: \(error)")
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardOutput.write(Data("[proof-harness] \(message)\n".utf8))
    }
}
#endif
