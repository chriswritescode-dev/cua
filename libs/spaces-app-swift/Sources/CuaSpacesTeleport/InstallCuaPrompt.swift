// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import Foundation

/// The "Build Cua" affordance for a teleport the Keyvault refused, the same
/// as `requiresCuaApp` in `@trycua/cua/teleport`.
///
/// Moving a signed-in session goes through the Cua Keyvault, which only the
/// installed, signed Cua app hosts. An app that embeds the SDK is refused by
/// design with the `requires_cua_app` code; this turns that refusal into a
/// prompt (title, one line, a button to the repository) instead of the raw
/// error. The refusal itself is unchanged: nothing here retries or bypasses
/// it.
public struct InstallCuaPrompt: Equatable, Sendable {
    /// The repository Cua is built from (the CLI and the Cua app).
    public static let repositoryURL = URL(string: "https://github.com/trycua/cua")!
    /// Opens the Keyvault page of an installed Cua app: `cua://keyvault`, or
    /// `cua-local://keyvault` from Cua Spaces Local, whose bundle stamps its
    /// scheme as `CuaUrlScheme` (the two apps answer to different schemes).
    public static var openURL: URL { openURL(info: Bundle.main.infoDictionary) }

    /// [`openURL`] for the Info.plist `info`: its `CuaUrlScheme`, else `cua`.
    public static func openURL(info: [String: Any]?) -> URL {
        let scheme = ((info?["CuaUrlScheme"] as? String) ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        return URL(string: "\(scheme.isEmpty ? "cua" : scheme)://keyvault") ?? URL(string: "cua://keyvault")!
    }

    /// Cua is installed but not running (open it instead of building it).
    public let installed: Bool
    public let title: String
    public let message: String
    /// The button label.
    public let actionLabel: String
    /// The button target: always one of the constants above, never a URL
    /// taken from the error, so a remote message cannot supply the link.
    public let url: URL

    /// The prompt when `error` is the Keyvault's "needs the Cua app"
    /// refusal; `nil` for any other failure.
    public static func detect(_ error: Error) -> InstallCuaPrompt? {
        detect(String(describing: error) + "\n" + error.localizedDescription)
    }

    /// The same, for an error message or a tool result's text.
    public static func detect(_ text: String) -> InstallCuaPrompt? {
        guard text.range(of: #"\brequires_cua_app\b|\bRequiresCuaApp\b"#, options: .regularExpression) != nil
        else { return nil }
        let notRunning = text.range(of: #"installed but not running|needs the Cua app running"#,
                                    options: [.regularExpression, .caseInsensitive]) != nil
        return notRunning
            ? InstallCuaPrompt(
                installed: true,
                title: "Open Cua to teleport your session",
                message: "The Cua app keeps your logins in its Keyvault and asks you before sharing them. Open it, then try again.",
                actionLabel: "Open Cua",
                url: openURL)
            : InstallCuaPrompt(
                installed: false,
                title: "Build Cua to teleport your session",
                message: "The Cua app keeps your logins in its Keyvault and asks you before sharing them. "
                    + "Build it from the repository: git pull && apps/cua-spaces-macos/scripts/build-release.sh (macOS), or "
                    + "pnpm --dir apps/cua-spaces-desktop dist:mac (macOS), dist:win (Windows), dist:linux (Linux).",
                actionLabel: "Open the repository",
                url: repositoryURL)
    }
}
