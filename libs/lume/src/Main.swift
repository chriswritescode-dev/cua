import AppKit
import ArgumentParser
import Dispatch
import Foundation

@main
struct Lume: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "lume",
            abstract: "A lightweight CLI and local API server to build, run and manage macOS VMs.",
            version: Version.current,
            subcommands: CommandRegistry.allCommands,
            helpNames: .long
        )
    }
}

// MARK: - Version Management
extension Lume {
    enum Version {
        static let current: String = "0.6.1" // x-release-please-version
    }
}

// MARK: - ASCII Art Banner
extension Lume {
    static let banner = """
    \u{001B}[34m  ⠀⣀⣀⡀⠀⠀⠀⠀⢀⣀⣀⣀⡀⠘⠋⢉⠙⣷⠀⠀ ⠀
     ⠀⠀⢀⣴⣿⡿⠋⣉⠁⣠⣾⣿⣿⣿⣿⡿⠿⣦⡈⠀⣿⡇⠃⠀
     ⠀⠀⠀⣽⣿⣧⠀⠃⢰⣿⣿⡏⠙⣿⠿⢧⣀⣼⣷⠀⡿⠃⠀⠀
     ⠀⠀⠀⠉⣿⣿⣦⠀⢿⣿⣿⣷⣾⡏⠀⠀⢹⣿⣿⠀⠀⠀⠀⠀⠀
     ⠀⠀⠀⠀⠀⠉⠛⠁⠈⠿⣿⣿⣿⣷⣄⣠⡼⠟⠁\u{001B}[0m\u{001B}[1m  lume v\(Version.current)\u{001B}[0m
    \u{001B}[34m           macOS VM CLI and server\u{001B}[0m
    """

    static func printBanner() {
        print(banner)
        print()
    }

    static func shouldShowBanner() -> Bool {
        let args = CommandLine.arguments.dropFirst()
        // Show banner when: no args, --help, -h, help, or just the root command
        if args.isEmpty {
            return true
        }
        if args.contains("--help") || args.contains("-h") {
            return true
        }
        // Check if first arg is "help" (e.g., "lume help")
        if args.first == "help" && args.count == 1 {
            return true
        }
        return false
    }
}

// MARK: - Command Execution
extension Lume {
    public static func main() {
        if let runContext = directRunContext() {
            ProcessInfo.processInfo.processName = "Lume — \(runContext.vmName)"
            do {
                try NativeApplicationLoop.run(
                    showsStartupWindow: runContext.showsNativeDisplayAtLaunch
                ) {
                    await executeInvocation()
                }
            } catch {
                exit(withError: error)
            }
            return
        }

        Task {
            await executeInvocation()
            Foundation.exit(EXIT_SUCCESS)
        }
        dispatchMain()
    }

    private static func executeInvocation() async {
        // Print banner when showing help
        if shouldShowBanner() {
            printBanner()
        }

        do {
            try await executeCommand()
        } catch {
            exit(withError: error)
        }
    }

    private static func directRunContext() -> (
        vmName: String,
        showsNativeDisplayAtLaunch: Bool
    )? {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "run", !args.contains("--detach") else { return nil }

        let noDisplay = args.contains("--no-display") || args.contains("-d")
        let inlineDisplay = args.first(where: { $0.hasPrefix("--display=") })
            .map { String($0.dropFirst("--display=".count)) }
        let separatedDisplay = args.indices.first(where: { index in
            args[index] == "--display" && args.index(after: index) < args.endIndex
        }).map { args[args.index(after: $0)] }
        let requestedDisplay = inlineDisplay ?? separatedDisplay
        let usesNativeDisplay = !noDisplay
            && (requestedDisplay == nil || requestedDisplay == DisplayMode.native.rawValue)

        // The conventional form is `lume run VM_NAME [options]`. ArgumentParser
        // still produces a useful validation error if the positional name is absent.
        let vmName = args.count > 1 && !args[1].hasPrefix("-") ? args[1] : "VM"
        return (vmName, usesNativeDisplay)
    }

    private static func executeCommand() async throws {
        var command = try parseAsRoot()

        if var asyncCommand = command as? AsyncParsableCommand {
            try await asyncCommand.run()
        } else {
            try command.run()
        }
    }
}
