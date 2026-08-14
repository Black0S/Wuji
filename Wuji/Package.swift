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
    dependencies: [
        // Le convertisseur de règles d'AdGuard, celui qu'utilisent leurs produits Safari
        // et wBlock. Il traduit vers WebKit **et** met de côté ce que WebKit ne sait pas
        // faire — scriptlets, sélecteurs étendus — au lieu de le perdre.
        //
        // GPL-3.0 : Wuji devient GPL le jour où il est distribué. C'est le prix de ne pas
        // réécrire dix ans de cas particuliers, et il est assumé.
        .package(url: "https://github.com/AdguardTeam/SafariConverterLib", from: "4.3.0"),
        // La liste des suffixes publics. Elle sert à savoir ce qu'est « ce site » : sans
        // elle, lever la protection sur `foo.github.io` la lèverait sur tout `github.io`,
        // c'est-à-dire sur les pages de tout le monde. Aucune heuristique ne remplace la
        // liste — c'est précisément le genre de question où deviner est dangereux.
        .package(url: "https://github.com/ameshkov/swift-psl", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Wuji",
            dependencies: [
                .product(name: "ContentBlockerConverter", package: "SafariConverterLib"),
                .product(name: "PublicSuffixList", package: "swift-psl")
            ],
            path: "Sources/Wuji"
        )
    ]
)
