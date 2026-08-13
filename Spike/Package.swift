// swift-tools-version: 6.2
import PackageDescription

// J0 — Spike. Code jetable : il répond à quatre questions binaires, il ne va pas en production.
// Volontairement un exécutable SPM et non un projet Xcode : boucle `swift run` en quelques
// secondes, rien à maintenir, et rien qui préjuge de l'arborescence finale (spec §6.1).
let package = Package(
    name: "WujiSpike",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "WujiSpike", path: "Sources/WujiSpike")
    ]
)
