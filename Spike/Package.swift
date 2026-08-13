// swift-tools-version: 6.2
import PackageDescription

// J0 — Spike. Code jetable : il répond à quatre questions binaires, il ne va pas en production.
// Volontairement un exécutable SPM et non un projet Xcode : boucle `swift run` en quelques
// secondes et rien à maintenir.
//
// Les sous-dossiers de Sources/WujiSpike préfigurent les paquets de la spec §6.1 —
// DesignSystem, Chrome, WebContent, Settings… Une seule cible pour l'instant : on
// n'extrait un paquet que le jour où un module doit devenir désactivable.
let package = Package(
    name: "WujiSpike",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "WujiSpike", path: "Sources/WujiSpike")
    ]
)
