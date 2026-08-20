// swift-tools-version: 6.2
import PackageDescription

// Wuji — un navigateur pour macOS.
// Copyright © 2026 Liam Jutteau (Black0S). Sous GPL-3.0 : voir le fichier LICENSE.

// Exécutable SPM plutôt que projet Xcode : boucle `swift build` en quelques secondes,
// rien à maintenir, et le bundle .app s'assemble dans run.sh.
//
// Les sous-dossiers de Sources nomment les domaines du projet — DesignSystem, Chrome,
// WebContent, Blocking, Settings… Une seule cible pour l'instant : on n'extrait un paquet
// que le jour où un module doit devenir désactivable.
let package = Package(
    name: "Wuji",
    platforms: [.macOS(.v26)],
    // **Aucune dépendance.** Il y en avait une — la liste des suffixes publics — et elle
    // est maintenant dans `Sources/PublicSuffix`, recopiée avec sa licence MIT. Ce n'est pas
    // une préférence : SwiftPM range les ressources d'une dépendance à la racine du paquet
    // `.app`, et macOS refuse de signer une application qui porte quoi que ce soit à cet
    // endroit. Le choix était donc entre la dépendance et la distribution.
    targets: [
        .executableTarget(
            name: "Wuji",
            // `Sources` et non `Sources/Wuji`, comme le voudrait la convention de SwiftPM.
            // Le dépôt s'appelle déjà Wuji et le paquet aussi : le chemin complet répétait
            // le nom trois fois pour atteindre un fichier. Une seule cible ici, donc rien
            // à départager — le jour où il en faudra deux, ce sera à revoir.
            path: "Sources",
            // Les règles ne sont pas une ressource SwiftPM : elles sont copiées dans le
            // paquet par `build.sh`, à côté de l'application, pas dans un bundle de
            // module. Le dire évite l'avertissement — et surtout évite qu'on les embarque
            // deux fois le jour où quelqu'un « corrige » l'avertissement à l'aveugle.
            exclude: ["Blocking/Assets", "PublicSuffix/Data", "PublicSuffix/LICENSE"]
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
