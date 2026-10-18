// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import AppKit
import CuaSDK
import CuaSpacesFFI
import Foundation
import Observation
import Sparkle

/// What Settings → About drives: Sparkle's `SPUUpdater` in the shipped app,
/// an in-memory updater in tests and captures.
@MainActor
public protocol UpdaterDriving: AnyObject {
    /// Checks on its own (Sparkle's `automaticallyChecksForUpdates`).
    var automaticallyChecks: Bool { get set }
    /// The last check (`lastUpdateCheckDate`).
    var lastCheck: Date? { get }
    /// Check Now can run (`canCheckForUpdates`; false while a check runs).
    var canCheck: Bool { get }
    /// Called after any of the above changes.
    var onChange: (() -> Void)? { get set }
    /// The Sparkle channels to check besides the default one.
    var channels: [String] { get set }
    /// A check the user started is running.
    var checking: Bool { get }
    /// The update the page shows (the bridge's `update.get`).
    var state: UpdateState { get }
    /// Checks now, with no Sparkle window: a found release is reported here,
    /// never downloaded.
    func checkNow()
}

/// Sparkle with no windows of its own (`UpdateUserDriver`): a check reports
/// a newer release and declines to download it. Signature checks are
/// Sparkle's, whatever the user driver. Started only in an app bundle whose
/// Info.plist names a feed and the EdDSA key (`SUFeedURL`, `SUPublicEDKey`).
@MainActor
public final class SparkleUpdater: NSObject, UpdaterDriving, SPUUpdaterDelegate {
    private var updater: SPUUpdater!
    private let driver: UpdateUserDriver
    private var observations: [NSKeyValueObservation] = []
    public var onChange: (() -> Void)?
    public var channels: [String] = []

    /// The updater for `bundle`, started; nil when the bundle has no feed
    /// (a development build) or Sparkle refused to start.
    public static func start(bundle: Bundle = .main, channels: [String]) -> SparkleUpdater? {
        guard bundle.bundleURL.pathExtension == "app",
              bundle.object(forInfoDictionaryKey: "SUFeedURL") is String,
              bundle.object(forInfoDictionaryKey: "SUPublicEDKey") is String else { return nil }
        let updater = SparkleUpdater(channels: channels, bundle: bundle)
        do {
            try updater.updater.start()
        } catch {
            NSLog("Cua Spaces: the updater did not start: %@", error.localizedDescription)
            return nil
        }
        return updater
    }

    private init(channels: [String], bundle: Bundle) {
        self.channels = channels
        driver = UpdateUserDriver(currentVersion: AboutBundleInfo(bundle: bundle).version)
        super.init()
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
        updater.automaticallyDownloadsUpdates = false
        driver.onChange = { [weak self] in self?.onChange?() }
        let changed: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.onChange?() }
        }
        observations = [
            updater.observe(\.canCheckForUpdates) { _, _ in changed() },
            updater.observe(\.lastUpdateCheckDate) { _, _ in changed() },
            updater.observe(\.automaticallyChecksForUpdates) { _, _ in changed() },
        ]
    }

    public var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    public var lastCheck: Date? { updater.lastUpdateCheckDate }
    public var canCheck: Bool { updater.canCheckForUpdates }
    public var state: UpdateState { driver.state }
    public var checking: Bool { driver.state.status == .checking }

    public func checkNow() {
        // Sparkle starts no check while one runs.
        guard updater.canCheckForUpdates, [.idle, .error].contains(driver.state.status) else { return }
        driver.beginUserCheck()
        updater.checkForUpdates()
    }

    /// Checks in the background (no window);
    /// end-to-end runs use it through `CUA_SPACES_UPDATE_CHECK`.
    public func checkInBackground() { updater.checkForUpdatesInBackground() }

    // Sparkle calls its delegate on the main thread.

    public nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { Set(channels) }
    }

    /// A cycle that ended with nothing to show clears a pending "checking".
    public nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                                    error: (any Error)?) {
        MainActor.assumeIsolated { driver.cycleFinished() }
    }
}


/// An in-memory updater (tests, captures): nothing is checked or stored.
@MainActor
public final class FixtureUpdater: UpdaterDriving {
    public var automaticallyChecks = true { didSet { onChange?() } }
    public var lastCheck: Date?
    public var canCheck = true
    public var onChange: (() -> Void)?
    public var channels: [String] = []
    public private(set) var checks = 0
    /// What the page shows; scripted by tests through the `simulate` calls.
    public var state = UpdateState.idle(currentVersion: "0.0.0") { didSet { onChange?() } }
    public var checking: Bool { state.status == .checking }

    public init(lastCheck: Date? = nil) { self.lastCheck = lastCheck }

    public func checkNow() {
        checks += 1
        lastCheck = Date()
        onChange?()
    }

    /// A check found `version`; it is reported, never downloaded.
    public func simulateFound(version: String) {
        state = UpdateState(status: .available, currentVersion: state.currentVersion, version: version,
                            notesUrl: UpdateState.notesURL(version: version),
                            instructions: UpdateState.manualUpdateMessage(version: version))
    }

    public func simulateError(_ message: String) {
        state = UpdateState(status: .error, currentVersion: state.currentVersion, message: message)
    }
}

/// Settings → About: the core's `appAboutView` over the updater's state.
/// The channel is an app setting (`AppSettings.updateChannel`); the rest is
/// Sparkle's own.
@MainActor
@Observable
public final class UpdatesModel {
    public let updater: UpdaterDriving?
    private let info: AboutBundleInfo
    /// Bumped when the updater changes, so the view recomputes.
    private var revision = 0
    /// The chosen channel and where it is saved.
    public var channel: AppUpdateChannel {
        didSet {
            updater?.channels = appAboutAllowedChannels(channel: channel)
            saveChannel(channel)
        }
    }
    @ObservationIgnored public var saveChannel: (AppUpdateChannel) -> Void = { _ in }
    /// Told once per found release, with the instructions to show.
    @ObservationIgnored public var onAvailable: ((String) -> Void)?
    /// The release already announced.
    @ObservationIgnored private var announced: String?

    public init(updater: UpdaterDriving?, channel: AppUpdateChannel = .stable,
                info: AboutBundleInfo = AboutBundleInfo(bundle: .main)) {
        self.updater = updater
        self.info = info
        self.channel = channel
        updater?.channels = appAboutAllowedChannels(channel: channel)
        updater?.onChange = { [weak self] in self?.changed() }
    }

    private func changed() {
        revision += 1
        let state = updateState
        guard let version = state.version, version != announced else { return }
        announced = version
        onAvailable?(state.instructions ?? UpdateState.manualUpdateMessage(version: version))
    }

    /// The pane, from the core.
    public var view: AppAboutView { appAboutView(input: input) }

    /// What the pane is built from: the app, and the updater's state.
    public var input: AppAboutInput {
        _ = revision
        return AppAboutInput(
            platform: "macos", version: info.version, build: info.build, os: info.os,
            updater: updater != nil,
            autoCheck: updater?.automaticallyChecks ?? false,
            channel: channel,
            lastCheck: updater?.lastCheck.map(Self.dateText),
            checking: updater?.checking ?? false)
    }

    /// What the page shows about an update (`update.get`).
    public var updateState: UpdateState {
        _ = revision
        var state = updater?.state ?? .idle(currentVersion: info.version)
        state.currentVersion = info.version
        return state
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    public func setAutoCheck(_ on: Bool) {
        updater?.automaticallyChecks = on
        revision += 1
    }

    public func choose(channel id: String) {
        channel = id == "beta" ? .beta : .stable
    }

    public func checkNow() {
        updater?.checkNow()
    }
}

/// The version and machine lines the About pane shows.
public struct AboutBundleInfo: Sendable {
    /// The full version (`CuaVersion`, else `CFBundleShortVersionString`).
    public var version: String
    /// `CFBundleVersion`.
    public var build: String
    /// "macOS 26.0 (arm64)".
    public var os: String

    public init(version: String, build: String, os: String) {
        self.version = version
        self.build = build
        self.os = os
    }

    public init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        version = (info["CuaVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? short
        build = info["CFBundleVersion"] as? String ?? ""
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let patch = v.patchVersion > 0 ? ".\(v.patchVersion)" : ""
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        os = "macOS \(v.majorVersion).\(v.minorVersion)\(patch) (\(arch))"
    }
}
