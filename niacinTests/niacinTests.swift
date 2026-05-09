import Testing
import Foundation
@testable import niacin

// MARK: - ActivationDuration

struct ActivationDurationTests {
    @Test func indefinite() {
        let d = ActivationDuration.indefinite
        #expect(d.seconds == nil)
        #expect(d.timeInterval == nil)
        #expect(d.displayTitle == "Indefinitely")
        #expect(d.id == -1)
    }

    @Test func minutesFactory() {
        #expect(ActivationDuration.minutes(1).seconds == 60)
        #expect(ActivationDuration.minutes(15).seconds == 900)
        #expect(ActivationDuration.minutes(0).seconds == 0)
    }

    @Test func hoursFactory() {
        #expect(ActivationDuration.hours(1).seconds == 3600)
        #expect(ActivationDuration.hours(2).seconds == 7200)
        #expect(ActivationDuration.hours(4).seconds == 14400)
    }

    @Test func displayTitleSingularVsPlural() {
        #expect(ActivationDuration.minutes(1).displayTitle == "1 minute")
        #expect(ActivationDuration.minutes(5).displayTitle == "5 minutes")
        #expect(ActivationDuration.hours(1).displayTitle == "1 hour")
        #expect(ActivationDuration.hours(2).displayTitle == "2 hours")
    }

    @Test func displayTitleMixed() {
        // 1h 30m, 2h 15m, etc. — verify the "Xh Ym" branch
        let ninety = ActivationDuration(seconds: 90 * 60)
        #expect(ninety.displayTitle == "1h 30m")

        let twoHoursFifteen = ActivationDuration(seconds: 2 * 3600 + 15 * 60)
        #expect(twoHoursFifteen.displayTitle == "2h 15m")
    }

    @Test func timeIntervalRoundTrip() {
        #expect(ActivationDuration.minutes(15).timeInterval == 900)
        #expect(ActivationDuration.hours(2).timeInterval == 7200)
        #expect(ActivationDuration.indefinite.timeInterval == nil)
    }

    @Test func identifiableDistinctness() {
        // Two finite durations with different seconds must have distinct ids,
        // and indefinite (nil) must not collide with a real duration.
        let a = ActivationDuration.minutes(5)
        let b = ActivationDuration.minutes(10)
        let inf = ActivationDuration.indefinite
        #expect(a.id != b.id)
        #expect(a.id != inf.id)
        #expect(b.id != inf.id)
    }
}

// MARK: - ManagedPreferences resolution

@MainActor
struct ManagedPreferencesTests {
    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("niacin-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func write(_ contents: [String: Any], to url: URL) {
        (contents as NSDictionary).write(to: url, atomically: true)
    }

    private static func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private static func withPaths(_ paths: [String], _ body: () -> Void) {
        let original = ManagedPreferences.pathsProvider
        defer { ManagedPreferences.pathsProvider = original }
        ManagedPreferences.pathsProvider = { paths }
        body()
    }

    @Test func readsBoolFromSystemWidePlist() {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let plist = dir.appendingPathComponent("system.plist")
        Self.write(["enabled": false, "allowIndefinite": true], to: plist)

        Self.withPaths([plist.path]) {
            #expect(ManagedPreferences.isEnabled == false)
            #expect(ManagedPreferences.allowIndefinite == true)
        }
    }

    @Test func defaultsApplyWhenKeyAbsent() {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let plist = dir.appendingPathComponent("empty.plist")
        Self.write([:], to: plist)

        Self.withPaths([plist.path]) {
            #expect(ManagedPreferences.isEnabled == true)
            #expect(ManagedPreferences.allowIndefinite == true)
            #expect(ManagedPreferences.allowUserToDisable == true)
            #expect(ManagedPreferences.disableQuit == false)
            #expect(ManagedPreferences.activateOnLaunch == nil)
            #expect(ManagedPreferences.maxDurationSeconds == nil)
            #expect(ManagedPreferences.allowedDurations == nil)
        }
    }

    @Test func perUserPlistTakesPrecedenceOverSystemWide() {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let user = dir.appendingPathComponent("user.plist")
        let system = dir.appendingPathComponent("system.plist")
        Self.write(["enabled": false], to: user)
        Self.write(["enabled": true], to: system)

        Self.withPaths([user.path, system.path]) {
            #expect(ManagedPreferences.isEnabled == false)
        }
    }

    @Test func systemWideUsedWhenPerUserMissing() {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let user = dir.appendingPathComponent("user.plist") // not created
        let system = dir.appendingPathComponent("system.plist")
        Self.write(["enabled": false], to: system)

        Self.withPaths([user.path, system.path]) {
            #expect(ManagedPreferences.isEnabled == false)
        }
    }

    @Test func intDecoding() {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let plist = dir.appendingPathComponent("p.plist")
        Self.write(["maxDurationSeconds": 14400], to: plist)

        Self.withPaths([plist.path]) {
            #expect(ManagedPreferences.maxDurationSeconds == 14400)
        }
    }

    @Test func boolEncodedAsNumberStillDecodes() {
        // Some MDMs encode booleans as integer 0/1 — the NSNumber.boolValue
        // path must still produce the correct answer.
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let plist = dir.appendingPathComponent("p.plist")
        Self.write(["enabled": NSNumber(value: 0), "allowIndefinite": NSNumber(value: 1)], to: plist)

        Self.withPaths([plist.path]) {
            #expect(ManagedPreferences.isEnabled == false)
            #expect(ManagedPreferences.allowIndefinite == true)
        }
    }

    @Test func allowedDurationsArrayDecodes() {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let plist = dir.appendingPathComponent("p.plist")
        Self.write(["allowedDurations": [900, 1800, 3600]], to: plist)

        Self.withPaths([plist.path]) {
            #expect(ManagedPreferences.allowedDurations == [900, 1800, 3600])
        }
    }

    @Test func allowedDurationsEmptyArrayReturnsNil() {
        // An empty array is treated as "no override" rather than "no
        // durations allowed" — otherwise an MDM that ships an empty list
        // would lock the user out entirely.
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let plist = dir.appendingPathComponent("p.plist")
        Self.write(["allowedDurations": [Int]()], to: plist)

        Self.withPaths([plist.path]) {
            #expect(ManagedPreferences.allowedDurations == nil)
        }
    }

    @Test func malformedPlistFallsBackToDefaults() {
        // Non-plist contents — NSDictionary(contentsOfFile:) returns nil and
        // managedValue should keep walking instead of crashing.
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let plist = dir.appendingPathComponent("broken.plist")
        try? "not a plist".write(to: plist, atomically: true, encoding: .utf8)

        Self.withPaths([plist.path]) {
            #expect(ManagedPreferences.isEnabled == true)
            #expect(ManagedPreferences.maxDurationSeconds == nil)
        }
    }

    @Test func isManagedReportsWhetherKeyIsInPlist() {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let plist = dir.appendingPathComponent("p.plist")
        Self.write(["enabled": true], to: plist)

        Self.withPaths([plist.path]) {
            #expect(ManagedPreferences.isManaged(key: "enabled") == true)
            #expect(ManagedPreferences.isManaged(key: "allowDisplaySleep") == false)
        }
    }
}

// MARK: - AppState.availableDurations filtering

@MainActor
struct AvailableDurationsTests {
    private static func withPolicy(_ policy: [String: Any], _ body: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("niacin-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plist = dir.appendingPathComponent("p.plist")
        (policy as NSDictionary).write(to: plist, atomically: true)

        let original = ManagedPreferences.pathsProvider
        defer { ManagedPreferences.pathsProvider = original }
        ManagedPreferences.pathsProvider = { [plist.path] }

        body()
    }

    // availableDurations only depends on ManagedPreferences statics, so the
    // shared AppState's session state doesn't affect these assertions.

    @Test func defaultListWhenNoPolicy() {
        Self.withPolicy([:]) {
            let durations = AppState.shared.availableDurations
            // indefinite + 5/10/15/30 min + 1h + 2h
            #expect(durations.count == 7)
            #expect(durations.first?.seconds == nil)            // indefinite leads
            #expect(durations.contains { $0.seconds == 300 })   // 5 min
            #expect(durations.contains { $0.seconds == 7200 })  // 2 hr
        }
    }

    @Test func allowedDurationsOverridesDefault() {
        Self.withPolicy(["allowedDurations": [900, 1800], "allowIndefinite": false]) {
            let durations = AppState.shared.availableDurations
            #expect(durations.count == 2)
            #expect(durations.map(\.seconds) == [900, 1800])
        }
    }

    @Test func maxDurationFiltersLongerOptions() {
        Self.withPolicy(["maxDurationSeconds": 1800]) {
            let durations = AppState.shared.availableDurations
            for d in durations {
                if let s = d.seconds {
                    #expect(s <= 1800)
                }
            }
            #expect(durations.contains { $0.seconds == nil })   // indefinite kept (allowIndefinite default true)
            #expect(durations.contains { $0.seconds == 1800 })
            #expect(!durations.contains { $0.seconds == 3600 })
        }
    }

    @Test func disallowIndefiniteRemovesIt() {
        Self.withPolicy(["allowIndefinite": false]) {
            let durations = AppState.shared.availableDurations
            #expect(!durations.contains { $0.seconds == nil })
            #expect(durations.allSatisfy { $0.seconds != nil })
        }
    }

    @Test func maxDurationAlsoBlocksIndefiniteWhenIndefiniteDisallowed() {
        Self.withPolicy(["maxDurationSeconds": 1800, "allowIndefinite": false]) {
            let durations = AppState.shared.availableDurations
            #expect(!durations.contains { $0.seconds == nil })
            #expect(durations.allSatisfy { ($0.seconds ?? Int.max) <= 1800 })
        }
    }

    @Test func allowedDurationsCombinedWithMaxDuration() {
        // Policy declares a fixed list, but maxDurationSeconds still trims
        // longer items — defence in depth when the two keys disagree.
        Self.withPolicy([
            "allowedDurations": [900, 3600, 14400],
            "maxDurationSeconds": 3600,
        ]) {
            let durations = AppState.shared.availableDurations
            #expect(durations.map(\.seconds) == [900, 3600])
        }
    }

    @Test func tinyMaxLeavesEmptyListIfIndefiniteDisallowed() {
        // maxDurationSeconds smaller than the smallest preset and indefinite
        // forbidden → no options. The UI surfaces "No durations available".
        Self.withPolicy([
            "maxDurationSeconds": 60,
            "allowIndefinite": false,
        ]) {
            let durations = AppState.shared.availableDurations
            #expect(durations.isEmpty)
        }
    }
}
