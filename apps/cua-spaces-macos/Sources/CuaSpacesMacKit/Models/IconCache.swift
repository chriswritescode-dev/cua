// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import AppKit
import Foundation

/// Where an app's icon comes from, resolved once per app: its bundle id and
/// version key the caches, `render` draws the PNG only on a cache miss.
public struct AppIconSource: Sendable {
    public let bundleId: String
    public let version: String
    public let render: @Sendable () -> Data?

    public init(bundleId: String, version: String, render: @escaping @Sendable () -> Data?) {
        self.bundleId = bundleId
        self.version = version
        self.render = render
    }
}

/// App icons for the Keyvault list. NSWorkspace is asked once per app and
/// version, never per render: a decoded image lives in an `NSCache`, the PNG
/// on disk under the bundle id and version, so a restart (or an app update,
/// which changes the key) costs one render at most.
public final class AppIconCache: @unchecked Sendable {
    public typealias Resolver = @Sendable (_ providerId: String, _ name: String) -> AppIconSource?

    private let dir: URL?
    private let resolver: Resolver
    private let memory = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    /// provider id to cache key (resolved once; "" when the app is not here).
    private var keys: [String: String] = [:]
    /// How often NSWorkspace was asked and an icon was drawn (the tests'
    /// proof that nothing is resolved per render).
    public private(set) var resolves = 0
    public private(set) var renders = 0

    public init(dir: URL?, resolver: @escaping Resolver = AppIconCache.workspace) {
        self.dir = dir
        self.resolver = resolver
        memory.countLimit = 256
    }

    /// The icon of an app, or nil (the list draws its first letter).
    public func image(providerId: String, name: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let key = keys[providerId] {
            return key.isEmpty ? nil : memory.object(forKey: key as NSString) ?? loadDisk(key)
        }
        resolves += 1
        guard let source = resolver(providerId, name) else {
            keys[providerId] = ""
            return nil
        }
        let key = AppIconCache.fileKey(source)
        keys[providerId] = key
        if let hit = memory.object(forKey: key as NSString) ?? loadDisk(key) { return hit }
        guard let png = source.render(), let image = NSImage(data: png) else {
            keys[providerId] = ""
            return nil
        }
        renders += 1
        memory.setObject(image, forKey: key as NSString)
        if let url = file(key) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? png.write(to: url, options: .atomic)
        }
        return image
    }

    static func fileKey(_ s: AppIconSource) -> String {
        let safe = { (v: String) in v.map { $0.isLetter || $0.isNumber || ".-_".contains($0) ? String($0) : "_" }.joined() }
        return "\(safe(s.bundleId))-\(safe(s.version))"
    }

    private func file(_ key: String) -> URL? { dir?.appendingPathComponent("\(key).png") }

    private func loadDisk(_ key: String) -> NSImage? {
        guard let url = file(key), let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    /// The bundle ids an app may have (the provider catalog's ids).
    static let bundleIds: [String: [String]] = [
        "chrome": ["com.google.Chrome"],
        "firefox": ["org.mozilla.firefox"],
        "slack": ["com.tinyspeck.slackmacgap"],
        "discord": ["com.hnc.Discord"],
        "steam": ["com.valvesoftware.steam"],
        "whatsapp": ["net.whatsapp.WhatsApp", "desktop.WhatsApp"],
        "claude-code": ["com.anthropic.claudefordesktop"],
    ]

    /// The real resolver: Launch Services for the app's location, its
    /// bundle for the version, NSWorkspace for the icon.
    public static let workspace: Resolver = { providerId, name in
        let ws = NSWorkspace.shared
        var url: URL?
        var id = ""
        for candidate in bundleIds[providerId] ?? [] {
            if let found = ws.urlForApplication(withBundleIdentifier: candidate) { url = found; id = candidate; break }
        }
        if url == nil {
            let guess = URL(fileURLWithPath: "/Applications/\(name).app")
            if FileManager.default.fileExists(atPath: guess.path) {
                url = guess
                id = Bundle(url: guess)?.bundleIdentifier ?? providerId
            }
        }
        guard let url else { return nil }
        let info = Bundle(url: url)?.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? (info?["CFBundleVersion"] as? String) ?? "0"
        return AppIconSource(bundleId: id, version: version) {
            let icon = ws.icon(forFile: url.path)
            return AppIconCache.png(icon, side: 64)
        }
    }

    static func png(_ image: NSImage, side: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
