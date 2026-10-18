// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import AppKit
import CuaSpacesFFI
@testable import CuaSpacesMacKit
import Foundation
import Testing

/// Icons and memoization: app icons resolved once per app and version, site
/// icons from the browser's own store with the globe standing in; and the
/// list model recomputed only when the vault or search change.
@MainActor
@Suite("Keyvault icons")
struct KeyvaultIconTests {
    nonisolated static func png(_ side: Int = 8, _ shade: CGFloat = 0.3) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: shade, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cua-icons-\(UUID().uuidString)")
    }

    // MARK: App icons

    @Test func anAppIsResolvedOnceNotPerRenderAndSurvivesARestart() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        final class Count: @unchecked Sendable { var resolved = 0; var drawn = 0 }
        let count = Count()
        let make: @Sendable (String) -> AppIconCache.Resolver = { version in
            { _, _ in
                count.resolved += 1
                return AppIconSource(bundleId: "com.google.Chrome", version: version) { count.drawn += 1; return Self.png() }
            }
        }
        let cache = AppIconCache(dir: dir, resolver: make("131.0"))
        for _ in 0..<50 { #expect(cache.image(providerId: "chrome", name: "Google Chrome") != nil) }
        #expect(count.resolved == 1 && count.drawn == 1, "50 renders, one NSWorkspace lookup and one drawing")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("com.google.Chrome-131.0.png").path))
        // A restart reads the PNG from disk: the app is looked up, not drawn.
        let again = AppIconCache(dir: dir, resolver: make("131.0"))
        #expect(again.image(providerId: "chrome", name: "Google Chrome") != nil)
        #expect(count.drawn == 1)
        // An update changes the version, so the icon is drawn again.
        let updated = AppIconCache(dir: dir, resolver: make("132.0"))
        #expect(updated.image(providerId: "chrome", name: "Google Chrome") != nil)
        #expect(count.drawn == 2)
        // An app that is not installed stays a letter and is not asked again.
        let none = AppIconCache(dir: dir, resolver: { _, _ in count.resolved += 1; return nil })
        let before = count.resolved
        #expect(none.image(providerId: "arc", name: "Arc") == nil)
        #expect(none.image(providerId: "arc", name: "Arc") == nil)
        #expect(count.resolved == before + 1)
    }

    // MARK: Site icons

    func model(favicons: [KvFavicon] = []) async -> (KeyvaultModel, FakeKeyvault) {
        let fake = FakeKeyvault(KeyvaultFixtures.overview())
        fake.favicons = favicons
        let m = KeyvaultModel(client: fake, clock: { Date(timeIntervalSince1970: Double(KeyvaultFixtures.now) / 1000) })
        await m.refresh()
        return (m, fake)
    }

    @Test func theBrowsersOwnIconShowsAndOtherwiseTheGlobe() async {
        let local = KvFavicon(site: "github.com", png: Self.png(16, 0.8).base64EncodedString())
        let (m, _) = await model(favicons: [local])
        await m.loadIcons()
        #expect(m.siteIcons["github.com"] != nil)
        #expect(m.siteIcons["notion.so"] == nil, "the globe stands in")
    }

    // MARK: Memoization

    @Test func theListModelRecomputesOnlyWhenTheVaultOrSearchChange() async {
        let (m, _) = await model()
        let k = m
        let base = k.computes["vaultView", default: 0]
        for _ in 0..<40 { _ = k.vaultView; _ = k.sidebar; _ = k.page }
        #expect(k.computes["vaultView", default: 0] <= base + 1, "40 renders, one computation")
        #expect(k.computes["sidebar", default: 0] <= 1)
        let once = k.computes["vaultView", default: 0]
        k.query = "github"
        _ = k.vaultView
        _ = k.vaultView
        #expect(k.computes["vaultView"] == once + 1, "a search recomputes once")
        k.send(KvVaultAction.toggleGroup(key: "chrome|github.com"))
        _ = k.vaultView
        #expect(k.computes["vaultView"] == once + 2)
        await k.refresh()
        _ = k.vaultView
        _ = k.vaultView
        #expect(k.computes["vaultView"] == once + 3, "a refresh recomputes once")
        #expect(k.vaultView.apps.flatMap(\.sites).allSatisfy { $0.site.contains("github") })
    }
}
