import ArgumentParser
import Foundation

struct CheckUpdate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-update",
        abstract: "Check whether a newer Lume release is available",
        discussion: """
            Read-only update check. Uses GitHub Releases, caches the result briefly,
            and never installs anything.
            """
    )

    @Flag(help: "Emit the structured update-state payload as JSON")
    var json: Bool = false

    @Flag(help: "Bypass the local update-check cache")
    var noCache: Bool = false

    func run() async throws {
        try await checkAndReportUpdate(noCache: noCache, json: json)
    }
}

struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check for a newer Lume release and how to rebuild from source",
        discussion: """
            Checks for a newer release. Lume never installs release builds; update a
            source checkout by pulling the repository and rebuilding it.
            """
    )

    @Flag(help: "Removed: installing release builds is disabled")
    var apply: Bool = false

    @Flag(help: "Emit the structured update-state payload as JSON")
    var json: Bool = false

    func run() async throws {
        if apply {
            throw ValidationError(
                "Installing release builds is disabled; update by pulling the repository and rebuilding: \(LumeVersionCheck.rebuildInstruction)"
            )
        }

        try await checkAndReportUpdate(noCache: false, json: json)
    }
}

private func checkAndReportUpdate(noCache: Bool, json: Bool) async throws {
    guard LumeVersionCheck.updateChecksEnabled() else {
        if json {
            try printJSON(LumeVersionCheck.disabledState())
        } else {
            print("Update checks disabled by LUME_UPDATE_CHECK.")
        }
        return
    }

    let state = await LumeVersionCheck.checkUpdateState(noCache: noCache)

    if json {
        try printJSON(state)
    }

    if let error = state.error {
        if !json {
            print("Update check failed: \(error)")
        }
        return
    }

    guard state.updateAvailable, let latest = state.latestVersion else {
        if !json {
            print("Up to date (Lume \(state.currentVersion)).")
        }
        return
    }

    if !json {
        print("Update available: Lume \(latest) (you have \(state.currentVersion)).")
        print("Update by pulling the repository and rebuilding: \(LumeVersionCheck.rebuildInstruction)")
    }
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    if let string = String(data: data, encoding: .utf8) {
        print(string)
    }
}
