// swift-tools-version: 6.2
import PackageDescription

// Exécutable SPM plutôt que projet Xcode : boucle `swift build` en quelques secondes,
// rien à maintenir, et le bundle .app s'assemble dans run.sh.
//
// Les sous-dossiers de Sources/Wuji préfigurent les paquets de la spec §6.1 —
// DesignSystem, Chrome, WebContent, Settings… Une seule cible pour l'instant : on
// n'extrait un paquet que le jour où un module doit devenir désactivable.
let package = Package(
    name: "Wuji",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Wuji", path: "Sources/Wuji")
    ]
)
