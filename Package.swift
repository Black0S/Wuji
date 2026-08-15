// swift-tools-version: 6.2
import PackageDescription

// Exécutable SPM plutôt que projet Xcode : boucle `swift build` en quelques secondes,
// rien à maintenir, et le bundle .app s'assemble dans run.sh.
//
// Les sous-dossiers de Sources nomment les domaines du projet — DesignSystem, Chrome,
// WebContent, Blocking, Settings… Une seule cible pour l'instant : on n'extrait un paquet
// que le jour où un module doit devenir désactivable.
let package = Package(
    name: "Wuji",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Le convertisseur d'AdGuard a été retiré, et avec lui l'obligation GPL-3 qu'il
        // imposait à la distribution. Il servait à traduire des listes téléchargées ; Wuji
        // livre maintenant ses règles déjà écrites dans le format de WebKit, et n'a donc
        // plus rien à traduire au démarrage. Il reste dans l'outil du dépôt qui régénère
        // l'asset, sur la machine du mainteneur — jamais dans le navigateur.
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
                .product(name: "PublicSuffixList", package: "swift-psl")
            ],
            // `Sources` et non `Sources/Wuji`, comme le voudrait la convention de SwiftPM.
            // Le dépôt s'appelle déjà Wuji et le paquet aussi : le chemin complet répétait
            // le nom trois fois pour atteindre un fichier. Une seule cible ici, donc rien
            // à départager — le jour où il en faudra deux, ce sera à revoir.
            path: "Sources",
            // Les règles ne sont pas une ressource SwiftPM : elles sont copiées dans le
            // paquet par `build.sh`, à côté de l'application, pas dans un bundle de
            // module. Le dire évite l'avertissement — et surtout évite qu'on les embarque
            // deux fois le jour où quelqu'un « corrige » l'avertissement à l'aveugle.
            exclude: ["Blocking/Assets"]
        ),
        // Les tests visent la logique pure : fabriquer une règle, nommer un site, relire
        // l'asset. Rien qui demande une fenêtre — ce qui se vérifie à l'œil se vérifie à
        // l'œil, et le reste doit se vérifier tout seul.
        .testTarget(
            name: "WujiTests",
            dependencies: ["Wuji"],
            path: "Tests/WujiTests"
        )
    ]
)
