import Foundation
import CodexBarCore

/// FORK-ONLY PROOF HARNESS (not shipped, not upstream): data-model compatibility check for PR #4800.
///
/// Decodes a real usage payload produced by the released v0.81.0 `CodexBarCLI` (a build from before
/// `UsageSnapshot.planObservation` existed), asserts the optional field decodes as nil, re-encodes
/// the snapshot with the new build's Codable model (field absent, no data loss), decodes the same
/// snapshot through `CLIUsageCache` (the persisted shape the shipped CLI reads), and maps it through
/// `HookEvent.usageUpdated` to show the plan fields are omitted when unavailable.
///
/// The payloads are real release-build output, but this decoder is a harness: the runner's GUI
/// session cannot reach the CLI cache fallback (it is gated to non-graphic sessions with a locked
/// keychain), so this clearly identifies which part is real vs harness.

enum CompatHarnessError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case let .message(text): text
        }
    }
}

struct OldProviderPayload: Decodable {
    let provider: String
    let usage: UsageSnapshot?
}

@main
struct ProofPlanCompat {
    static func main() {
        do {
            try self.run()
        } catch {
            FileHandle.standardError.write(Data("COMPAT FAILED: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            throw CompatHarnessError.message(
                "usage: ProofPlanCompat <v0.81.0-cli-usage.json> [<v0.81.0-cli-cache-usage.json>]")
        }
        let oldPayloadURL = URL(fileURLWithPath: arguments[1])
        let oldPayloadData = try Data(contentsOf: oldPayloadURL)
        let oldPayloadString = String(data: oldPayloadData, encoding: .utf8) ?? ""

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let payloads = try decoder.decode([OldProviderPayload].self, from: oldPayloadData)
        guard let oldUsage = payloads.first(where: { $0.provider == "codex" })?.usage else {
            throw CompatHarnessError.message("no codex provider payload in \(oldPayloadURL.path)")
        }

        // Round-trip through the new build's Codable model. The new field must stay absent.
        let roundTripData = try encoder.encode(oldUsage)
        let roundTripString = String(data: roundTripData, encoding: .utf8) ?? ""
        let roundTripObject = try JSONSerialization.jsonObject(with: roundTripData)

        // Persisted CLI cache shape: {"entries":[{"provider":"codex","usage":{...snapshot...}}]}.
        let cacheObject: [String: Any] = [
            "entries": [
                ["provider": "codex", "usage": roundTripObject],
            ],
        ]
        let cacheData = try JSONSerialization.data(withJSONObject: cacheObject, options: [.sortedKeys])
        let cache = try decoder.decode(CLIUsageCache.self, from: cacheData)
        let cacheEntry = cache.entries.first

        // Shared hook mapping: an unavailable observation must omit plan/planSource/planObservedAt.
        let event = HookEvent.usageUpdated(
            provider: "codex",
            snapshot: oldUsage,
            account: nil,
            timestamp: Date())
        let hookPayloadData = try event.jsonPayload()
        let hookPayloadObject = try JSONSerialization.jsonObject(with: hookPayloadData) as? [String: Any] ?? [:]
        let environment = event.environmentVariables()

        func number(_ window: RateWindow?) -> Any {
            window.map { $0.usedPercent } ?? NSNull()
        }

        let report: [String: Any] = [
            "harness": "ProofPlanCompat (fork-only, not shipped)",
            "oldPayload.path": oldPayloadURL.path,
            "oldPayload.source": "released CodexBarCLI v0.81.0 usage --format json",
            "oldPayload.hadPlanObservationKey": oldPayloadString.contains("\"planObservation\""),
            "oldPayload.decoded": true,
            "snapshot.primaryUsedPercent": number(oldUsage.primary),
            "snapshot.secondaryUsedPercent": number(oldUsage.secondary),
            "snapshot.updatedAt": ISO8601DateFormatter().string(from: oldUsage.updatedAt),
            "snapshot.planObservationIsNil": oldUsage.planObservation == nil,
            "snapshot.identityLoginMethod": oldUsage.identity?.loginMethod ?? NSNull(),
            "roundTrip.hasPlanObservationKey": roundTripString.contains("\"planObservation\""),
            "roundTrip.preservedPrimaryUsedPercent": number(oldUsage.primary),
            "usageCache.decoded": true,
            "usageCache.entryCount": cache.entries.count,
            "usageCache.provider": cacheEntry?.provider ?? NSNull(),
            "usageCache.planObservationIsNil": cacheEntry?.usage.planObservation == nil,
            "hookPayload.hasPlan": hookPayloadObject["plan"] != nil,
            "hookPayload.hasPlanSource": hookPayloadObject["planSource"] != nil,
            "hookPayload.hasPlanObservedAt": hookPayloadObject["planObservedAt"] != nil,
            "hookPayload.event": hookPayloadObject["event"] ?? NSNull(),
            "hookEnv.hasPlan": environment["CODEXBAR_PLAN"] != nil,
            "hookEnv.hasPlanSource": environment["CODEXBAR_PLAN_SOURCE"] != nil,
            "hookEnv.hasPlanObservedAt": environment["CODEXBAR_PLAN_OBSERVED_AT"] != nil,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        let reportData = try JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys])
        print(String(data: reportData, encoding: .utf8) ?? "{}")

        guard oldUsage.planObservation == nil,
              !oldPayloadString.contains("\"planObservation\""),
              !roundTripString.contains("\"planObservation\""),
              roundTripObject is [String: Any],
              cacheEntry?.usage.planObservation == nil,
              hookPayloadObject["plan"] == nil,
              hookPayloadObject["planSource"] == nil,
              hookPayloadObject["planObservedAt"] == nil,
              environment["CODEXBAR_PLAN"] == nil,
              environment["CODEXBAR_PLAN_SOURCE"] == nil,
              environment["CODEXBAR_PLAN_OBSERVED_AT"] == nil
        else {
            throw CompatHarnessError.message("compatibility assertions failed")
        }
        print("COMPAT OK")
    }
}
