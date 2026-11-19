import ArgumentParser
import Testing
import Virtualization

@testable import lume

private func parsedSharedDirectories(_ options: [String]) throws -> [SharedDirectory] {
    let root = try Lume.parseAsRoot(["run", "test-vm"] + options)
    let command = try #require(root as? Run)
    return try command.parsedSharedDirectories
}

@MainActor
@Test("run parses repeated additional disk options")
func runCommandParsesAdditionalDisks() throws {
    let root = try Lume.parseAsRoot([
        "run",
        "test-vm",
        "--disk",
        "scratch.img",
        "--disk=cache.img",
    ])
    let command = try #require(root as? Run)

    #expect(command.name == "test-vm")
    #expect(command.additionalDisks == ["scratch.img", "cache.img"])
}

@MainActor
@Test("run parses shared directory access modes and tags")
func runCommandParsesSharedDirectories() throws {
    let automount = VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
    let directories = try parsedSharedDirectories([
        "--shared-dir", "/tmp",
        "--shared-dir", "/tmp:ro",
        "--shared-dir", "/tmp:rw",
        "--shared-dir", "/tmp:rw:tag=src",
    ])

    #expect(directories.map(\.hostPath) == ["/tmp", "/tmp", "/tmp", "/tmp"])
    #expect(directories.map(\.tag) == [automount, automount, automount, "src"])
    #expect(directories.map(\.readOnly) == [false, true, false, false])
}

@MainActor
@Test("run rejects invalid shared directory components")
func runCommandRejectsInvalidSharedDirectories() throws {
    #expect(throws: ValidationError.self) {
        _ = try parsedSharedDirectories(["--shared-dir", "/tmp:rx"])
    }
    #expect(throws: ValidationError.self) {
        _ = try parsedSharedDirectories(["--shared-dir", "/tmp:rw:mode=src"])
    }
    #expect(throws: ValidationError.self) {
        _ = try parsedSharedDirectories(["--shared-dir", "/tmp:rw:tag=\(String(repeating: "a", count: 40))"])
    }
    #expect(throws: ValidationError.self) {
        _ = try parsedSharedDirectories(["--shared-dir", "/tmp:rw:tag="])
    }
}
