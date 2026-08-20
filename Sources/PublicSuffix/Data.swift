import Foundation

/// Où trouver les données de la liste des suffixes publics.
///
/// **C'est le seul écart avec la bibliothèque d'origine**, et il existe pour une raison de
/// structure. Le code que SwiftPM engendre pour une dépendance cherche ses ressources dans
/// un paquet posé à la racine de `Wuji.app`, à côté de `Contents`. macOS refuse de signer
/// une application qui porte quoi que ce soit à cet endroit — mesuré : « unsealed contents
/// present in the bundle root ». Sans signature, pas de notarisation, donc pas de
/// distribution. Les données sont donc dans `Contents/Resources`, là où macOS les attend.
///
/// Le repli sur le dépôt sert aux tests, qui s'exécutent hors de toute application. Il ne
/// s'active jamais dans le paquet livré : ce chemin n'y existe pas.
enum PublicSuffixData {

    static func url(of name: String) -> URL? {
        if let inBundle = Bundle.main.url(forResource: name, withExtension: "bin") {
            return inBundle
        }
        let inRepository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Data/\(name).bin")
        return FileManager.default.fileExists(atPath: inRepository.path) ? inRepository : nil
    }

    /// La date de la liste embarquée, telle que ses auteurs l'ont horodatée. Affichée nulle
    /// part pour l'instant — elle sert à savoir ce qu'on livre.
    static var version: String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Data/version.txt")
        return (try? String(contentsOf: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "inconnue"
    }
}
