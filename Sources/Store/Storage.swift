import Foundation

/// Où Wuji range ce qui vous appartient.
///
/// **Un seul endroit qui le sait.** Cinq classes calculaient ce chemin chacune de son
/// côté, avec cinq occasions de diverger — et l'une écrivait déjà dans un sous-dossier
/// différent des autres sans que ce soit voulu.
///
/// **Et un chemin qu'on peut remplacer.** Sans ça, un test qui vérifie qu'on sait écrire
/// une session écraserait la vraie : on détruirait les onglets de quelqu'un pour prouver
/// qu'on sait les garder. Le dossier se passe donc en paramètre, avec le vrai pour valeur
/// par défaut.
enum Storage {

    /// `~/Library/Application Support/Wuji`, créé au besoin.
    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("Wuji", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
