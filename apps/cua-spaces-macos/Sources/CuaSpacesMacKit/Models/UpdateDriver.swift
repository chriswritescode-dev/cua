// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import AppKit
import Foundation
import Sparkle

/// What the page shows about an update, the JSON behind the bridge's
/// `update.get`:
/// `{status, currentVersion, version, notesUrl, instructions, message}`.
public struct UpdateState: Equatable, Sendable {
    public enum Status: String, Sendable {
        case idle, checking, available, error
    }

    public var status: Status
    /// This app's full version.
    public var currentVersion: String
    /// The newer release the last check found.
    public var version: String?
    public var notesUrl: String?
    /// How to update by hand; nil unless an update is available.
    public var instructions: String?
    /// Why the last check failed (`error` only).
    public var message: String?

    public init(status: Status = .idle, currentVersion: String, version: String? = nil,
                notesUrl: String? = nil, instructions: String? = nil, message: String? = nil) {
        self.status = status
        self.currentVersion = currentVersion
        self.version = version
        self.notesUrl = notesUrl
        self.instructions = instructions
        self.message = message
    }

    public static func idle(currentVersion: String) -> UpdateState { UpdateState(currentVersion: currentVersion) }

    /// The release's page: the repository's tag for a Cua Spaces version.
    public static func notesURL(version: String) -> String {
        "https://github.com/trycua/cua/releases/tag/cua-spaces-v\(version)"
    }

    /// What a found release says: this app notifies, it never installs.
    public static func manualUpdateMessage(version: String) -> String {
        "A newer Cua Spaces release (\(version)) is available. Update by pulling the repository and rebuilding: "
            + "git pull && apps/cua-spaces-macos/scripts/build-release.sh"
    }

    /// The bridge's record; absent values are explicit nulls.
    public var json: [String: Any] {
        [
            "status": status.rawValue,
            "currentVersion": currentVersion,
            "version": version.map { $0 as Any } ?? NSNull(),
            "notesUrl": notesUrl.map { $0 as Any } ?? NSNull(),
            "instructions": instructions.map { $0 as Any } ?? NSNull(),
            "message": message.map { $0 as Any } ?? NSNull(),
        ]
    }
}

/// The update state machine over plain values (no Sparkle types), so each
/// step is testable. `UpdateUserDriver` feeds it Sparkle's callbacks.
public struct UpdateFlow: Equatable, Sendable {
    public private(set) var state: UpdateState
    /// A check the user started (its errors are shown).
    public private(set) var userCheck = false

    public init(currentVersion: String) { state = .idle(currentVersion: currentVersion) }

    /// A user-visible check begins.
    public mutating func userCheckStarted() {
        userCheck = true
        state = UpdateState(status: .checking, currentVersion: state.currentVersion)
    }

    /// A newer release was found: it is reported, never downloaded or
    /// installed. The instruction says to pull the repository and rebuild.
    public mutating func found(version: String) {
        state = UpdateState(status: .available, currentVersion: state.currentVersion, version: version,
                            notesUrl: UpdateState.notesURL(version: version),
                            instructions: UpdateState.manualUpdateMessage(version: version))
    }

    public mutating func notFound() {
        userCheck = false
        state = .idle(currentVersion: state.currentVersion)
    }

    public mutating func failed(_ message: String) {
        userCheck = false
        state = UpdateState(status: .error, currentVersion: state.currentVersion, message: message)
    }

    /// Sparkle ended its session. A found release stays reported (its
    /// session ended because the app declined it); only a check nobody saw
    /// end becomes idle.
    public mutating func dismissed() {
        userCheck = false
        if state.status == .checking { state = .idle(currentVersion: state.currentVersion) }
    }
}

/// Sparkle's user driver without windows: a check reports what it found and
/// declines every download, so this app never installs an update itself.
@MainActor
public final class UpdateUserDriver: NSObject, SPUUserDriver {
    public private(set) var flow: UpdateFlow
    /// Told after every state change.
    public var onChange: (() -> Void)?
    /// Shows an error to the person who started the check.
    var presentError: (String) -> Void = UpdateUserDriver.alertError

    public var state: UpdateState { flow.state }

    public init(currentVersion: String) {
        flow = UpdateFlow(currentVersion: currentVersion)
        super.init()
    }

    private func changed(_ edit: (inout UpdateFlow) -> Void) {
        let before = flow
        edit(&flow)
        if flow != before { onChange?() }
    }

    /// The user pressed Check Now.
    public func beginUserCheck() { changed { $0.userCheckStarted() } }

    /// The update cycle ended; a check nobody saw end is idle.
    public func cycleFinished() {
        if flow.state.status == .checking { changed { $0.dismissed() } }
    }

    // MARK: - Update found

    /// What `showUpdateFound` does, over plain values.
    func handleFound(version: String, informationOnly: Bool, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !informationOnly else {
            reply(.dismiss)
            return
        }
        changed { $0.found(version: version) }
        reply(.dismiss)
    }

    public func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                reply: @escaping (SPUUserUpdateChoice) -> Void) {
        handleFound(version: appcastItem.displayVersionString, informationOnly: appcastItem.isInformationOnlyUpdate,
                    reply: reply)
    }

    // MARK: - SPUUserDriver

    public func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, automaticUpdateDownloading: false as NSNumber,
                                         sendSystemProfile: false))
    }

    public func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { beginUserCheck() }

    public func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    public func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    public func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        changed { $0.notFound() }
        acknowledgement()
    }

    public func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        handleError(error.localizedDescription)
        acknowledgement()
    }

    /// A background error is logged only; the check's user sees an alert.
    func handleError(_ message: String) {
        let shown = flow.userCheck
        NSLog("Cua Spaces: the updater failed: %@", message)
        changed { $0.failed(message) }
        if shown { presentError(message) }
    }

    public func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    public func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    public func showDownloadDidReceiveData(ofLength length: UInt64) {}
    public func showDownloadDidStartExtractingUpdate() {}
    public func showExtractionReceivedProgress(_ progress: Double) {}

    public func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(.dismiss)
    }

    public func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                                     retryTerminatingApplication: @escaping () -> Void) {}

    public func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    public func showUpdateInFocus() {}

    public func dismissUpdateInstallation() {
        changed { $0.dismissed() }
    }

    private static func alertError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Update Error!"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
