// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import CuaSDK
import CuaSpacesFFI
@testable import CuaSpacesMacKit
import Foundation
import Sparkle
import Testing

/// Settings → About over an in-memory updater, and the first launch after
/// an update: the version recorded in the settings file, whose daemon
/// restarts and what `cua agents update` failing shows. No process runs:
/// the bundled `cua` is a scripted fake.
@Suite("Updates")
@MainActor
struct UpdatesTests {
    static let info = AboutBundleInfo(version: "0.2.0-staging.5", build: "0.2.0.105", os: "macOS 26.0 (arm64)")

    @Test func theAboutPaneFollowsTheUpdater() {
        let updater = FixtureUpdater()
        let model = UpdatesModel(updater: updater, channel: .stable, info: Self.info)
        var v = model.view
        #expect(v.title == "Cua Spaces for macOS")
        #expect(v.versionLine == "Version 0.2.0-staging.5 (0.2.0.105)")
        #expect(v.links.map(\.label) == ["Acknowledgements", "Privacy Policy", "Terms of Service", "System Status", "Report an Issue\u{2026}"])
        #expect(v.updates?.lastCheck == "Last check: Never")
        #expect(v.updates?.autoCheckLabel == "Check for updates automatically")

        model.setAutoCheck(false)
        #expect(!updater.automaticallyChecks)
        model.setAutoCheck(true)
        #expect(updater.automaticallyChecks)

        model.checkNow()
        #expect(updater.checks == 1)
        v = model.view
        #expect(v.updates?.lastCheck.hasPrefix("Last check: ") == true)
        #expect(v.updates?.lastCheck != "Last check: Never")
    }

    /// Updates are a notification: the app checks on its own and never
    /// downloads or installs a release.
    @Test func updatesAreCheckedButNeverDownloaded() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Support/Info.plist")
        let info = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(info["SUAutomaticallyUpdate"] as? Bool == false)
    }

    @Test func noUpdaterNoControls() {
        let model = UpdatesModel(updater: nil, info: Self.info)
        #expect(model.view.updates == nil)
        #expect(model.view.links.count == 5)
    }

    @Test func theChannelIsSavedAndGivesSparkleItsChannels() {
        let updater = FixtureUpdater()
        let model = UpdatesModel(updater: updater, channel: .stable, info: Self.info)
        var saved: [AppUpdateChannel] = []
        model.saveChannel = { saved.append($0) }
        #expect(updater.channels.isEmpty)
        model.choose(channel: "beta")
        #expect(updater.channels == ["beta"])
        #expect(saved == [.beta])
        #expect(model.view.updates?.channels.first(where: \.active)?.id == "beta")
        model.choose(channel: "stable")
        #expect(updater.channels.isEmpty)
        #expect(saved == [.beta, .stable])
    }

    // MARK: - The in-app update notice

    @Test func aFoundUpdateIsReportedAndNeverInstalled() {
        let updater = FixtureUpdater()
        let model = UpdatesModel(updater: updater, channel: .stable, info: Self.info)
        var announced: [String] = []
        model.onAvailable = { announced.append($0) }
        #expect(model.updateState.status == .idle)
        #expect(model.updateState.currentVersion == "0.2.0-staging.5")
        updater.simulateFound(version: "0.2.0-staging.6")
        #expect(model.updateState.status == .available)
        #expect(model.updateState.version == "0.2.0-staging.6")
        #expect(model.updateState.notesUrl == "https://github.com/trycua/cua/releases/tag/cua-spaces-v0.2.0-staging.6")
        let instructions = "A newer Cua Spaces release (0.2.0-staging.6) is available. "
            + "Update by pulling the repository and rebuilding: git pull && apps/cua-spaces-macos/scripts/build-release.sh"
        #expect(model.updateState.instructions == instructions)
        #expect(model.updateState.message == nil)
        #expect(announced == [instructions])
        // The same release is announced once.
        updater.simulateFound(version: "0.2.0-staging.6")
        #expect(announced == [instructions])
    }

    @Test func theStateJSONHasTheContractsKeys() {
        let idle = UpdateState.idle(currentVersion: "0.9.2").json
        #expect(Set(idle.keys) == ["status", "currentVersion", "version", "notesUrl", "instructions", "message"])
        #expect(idle["status"] as? String == "idle")
        #expect(idle["version"] is NSNull && idle["notesUrl"] is NSNull && idle["instructions"] is NSNull && idle["message"] is NSNull)
        let found = UpdateState(status: .available, currentVersion: "0.9.2", version: "0.9.3",
                                notesUrl: UpdateState.notesURL(version: "0.9.3"),
                                instructions: UpdateState.manualUpdateMessage(version: "0.9.3")).json
        #expect(found["status"] as? String == "available")
        #expect(found["notesUrl"] as? String == "https://github.com/trycua/cua/releases/tag/cua-spaces-v0.9.3")
        #expect(found["instructions"] as? String == UpdateState.manualUpdateMessage(version: "0.9.3"))
        #expect(found["message"] is NSNull)
    }

    @Test func aFlowReducesSparklesSteps() {
        var flow = UpdateFlow(currentVersion: "0.9.2")
        flow.userCheckStarted()
        #expect(flow.state.status == .checking)
        flow.found(version: "0.9.3")
        #expect(flow.state.status == .available && flow.state.version == "0.9.3")
        #expect(flow.state.instructions == UpdateState.manualUpdateMessage(version: "0.9.3"))
        flow.dismissed()
        #expect(flow.state.status == .available && flow.state.version == "0.9.3")
        flow.userCheckStarted()
        flow.dismissed()
        #expect(flow.state.status == .idle && flow.state.version == nil)
    }

    final class Replies {
        var choices: [SPUUserUpdateChoice] = []
    }

    @Test func theDriverReportsAFoundUpdateAndDeclinesTheDownload() {
        let driver = UpdateUserDriver(currentVersion: "0.9.2")
        let replies = Replies()
        var changes = 0
        driver.onChange = { changes += 1 }
        driver.handleFound(version: "0.9.3", informationOnly: false) { replies.choices.append($0) }
        #expect(replies.choices == [.dismiss])
        #expect(driver.state.status == .available && driver.state.version == "0.9.3")
        #expect(driver.state.instructions?.contains("git pull && apps/cua-spaces-macos/scripts/build-release.sh") == true)
        #expect(changes > 0)
        // Nothing is ever ready to install.
        driver.showReady(toInstallAndRelaunch: { replies.choices.append($0) })
        #expect(replies.choices == [.dismiss, .dismiss])
    }

    @Test func nothingFoundAndBackgroundErrorsStayQuiet() {
        let driver = UpdateUserDriver(currentVersion: "0.9.2")
        var alerts: [String] = []
        driver.presentError = { alerts.append($0) }
        var acks = 0
        driver.showUpdateNotFoundWithError(NSError(domain: "t", code: 1)) { acks += 1 }
        #expect(acks == 1 && driver.state.status == .idle)
        driver.showUpdaterError(NSError(domain: "t", code: 2, userInfo: [NSLocalizedDescriptionKey: "offline"])) { acks += 1 }
        #expect(acks == 2 && alerts.isEmpty)
        #expect(driver.state.status == .error && driver.state.message == "offline")
        driver.dismissUpdateInstallation()
        #expect(driver.state.status == .error)
    }

    @Test func aUserCheckErrorShowsAnAlert() {
        let driver = UpdateUserDriver(currentVersion: "0.9.2")
        var alerts: [String] = []
        driver.presentError = { alerts.append($0) }
        driver.beginUserCheck()
        #expect(driver.state.status == .checking)
        driver.showUpdaterError(NSError(domain: "t", code: 2, userInfo: [NSLocalizedDescriptionKey: "offline"])) {}
        #expect(alerts == ["offline"])
    }

    @Test func aUserCheckThatFindsNothingEndsQuietly() {
        let driver = UpdateUserDriver(currentVersion: "0.9.2")
        driver.beginUserCheck()
        driver.showUpdateNotFoundWithError(NSError(domain: "t", code: 1)) {}
        #expect(driver.state.status == .idle)
    }

    @Test func anInformationOnlyItemIsNotInstalled() {
        let driver = UpdateUserDriver(currentVersion: "0.9.2")
        let replies = Replies()
        driver.handleFound(version: "1.0.0", informationOnly: true) { replies.choices.append($0) }
        #expect(replies.choices == [.dismiss])
        #expect(driver.state.status == .idle)
    }

    // MARK: - The launch after an update

    func settingsFile() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cua-updates-\(UUID().uuidString)", isDirectory: true)
        return dir.appendingPathComponent("settings.json").path
    }

    @Test func aVersionChangeRefreshesOnce() {
        let path = settingsFile()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        // A fresh install records its version and refreshes nothing.
        #expect(!UpdateRefresh.record(settingsPath: path, version: "0.2.0-staging.5", build: "0.2.0.105", onboarded: false))
        #expect(appSettingsLoad(path: path).lastSeenVersion == "0.2.0-staging.5 (0.2.0.105)")
        // Relaunching the same build: nothing.
        #expect(!UpdateRefresh.record(settingsPath: path, version: "0.2.0-staging.5", build: "0.2.0.105", onboarded: true))
        // The update to staging.6: refresh, once.
        #expect(UpdateRefresh.record(settingsPath: path, version: "0.2.0-staging.6", build: "0.2.0.106", onboarded: true))
        #expect(appSettingsLoad(path: path).lastSeenVersion == "0.2.0-staging.6 (0.2.0.106)")
        #expect(!UpdateRefresh.record(settingsPath: path, version: "0.2.0-staging.6", build: "0.2.0.106", onboarded: true))
    }

    @Test func recordingKeepsTheOtherSettings() {
        let path = settingsFile()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        var s = appSettingsLoad(path: path)
        s.menuBar = true
        s.updateChannel = .beta
        try? appSettingsSave(path: path, settings: s)
        // A build from before the updater kept no record: after the first
        // run, that is an update.
        #expect(UpdateRefresh.record(settingsPath: path, version: "0.2.0", build: "0.2.0.2", onboarded: true))
        let after = appSettingsLoad(path: path)
        #expect(after.menuBar && after.updateChannel == .beta)
    }

    /// Answers `cua` the way the real CLI does, recording each call.
    final class FakeCua: CommandRunning, @unchecked Sendable {
        var pid: Int32?
        var stopWorks = true
        var startStatus: Int32 = 0
        var agents = CommandResult(status: 0, output: #"{"outcomes":[]}"#)
        private(set) var calls: [String] = []
        private let lock = NSLock()

        func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
            lock.lock()
            defer { lock.unlock() }
            let call = arguments.joined(separator: " ")
            calls.append(call)
            switch call {
            case "--json daemon status":
                // Pretty-printed, as the CLI prints it.
                guard let pid else {
                    return CommandResult(status: 1, output: "{\n  \"mode\": \"embedded\",\n  \"pid\": null\n}\n")
                }
                return CommandResult(status: 0, output: "{\n  \"mode\": \"daemon\",\n  \"pid\": \(pid)\n}\n")
            case "daemon stop":
                if stopWorks { pid = nil }
                return CommandResult(status: 0, output: "stopped")
            case "daemon start":
                if startStatus == 0 { pid = 4242 }
                return CommandResult(status: startStatus, output: "")
            case "--json agents update":
                return agents
            default:
                return CommandResult(status: 2, output: "")
            }
        }
    }

    static let bundle = "/Applications/Cua Spaces.app"

    func refresh(_ cua: FakeCua) -> UpdateRefresh {
        UpdateRefresh(cua: Self.bundle + "/Contents/MacOS/cua", bundle: Self.bundle, runner: cua)
    }

    @Test func refreshedQuietly() {
        let cua = FakeCua()
        #expect(refresh(cua).run() == nil)
        #expect(cua.calls.contains("--json agents update"))
    }

    @Test func aFailedAgentsUpdateShowsOneNotice() {
        let cua = FakeCua()
        cua.agents = CommandResult(status: 1, output: """
            {
              "outcomes": [
                {"item": "cua", "change": "updated", "detail": ""},
                {"item": "cua-spaces", "change": "failed", "detail": "permission denied"}
              ]
            }
            """)
        let notice = refresh(cua).run()
        #expect(notice == "Cua Spaces updated, but could not refresh the Cua skills in your AI agents (cua-spaces: permission denied). Run `cua agents update` to try again.")
    }

    @Test func theCLIsPrettyJSONIsRead() {
        #expect(UpdateRefresh.json("{\n  \"pid\": 7\n}\n")?["pid"] as? Int == 7)
        #expect(UpdateRefresh.json("warning: something\n{\n  \"pid\": 8\n}")?["pid"] as? Int == 8)
        #expect(UpdateRefresh.json("no json") == nil)
    }

    @Test func theDaemonsExecutableIsReadFromItsPid() {
        let me = UpdateRefresh.executablePath(ProcessInfo.processInfo.processIdentifier)
        #expect(me != nil && FileManager.default.isExecutableFile(atPath: me!))
        #expect(UpdateRefresh.executablePath(-1) == nil)
        // The path it was started from (what an updated daemon still has
        // once its file is gone) names the same executable.
        #expect(UpdateRefresh.launchPath(ProcessInfo.processInfo.processIdentifier).map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        } == URL(fileURLWithPath: me!).resolvingSymlinksInPath().path)
    }
}
