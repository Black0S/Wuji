import Testing
import Foundation
@testable import Wuji

/// Une application qui se découpe en plusieurs extensions.
///
/// **C'est le cas ordinaire, pas l'exception.** Noir livre « Noir » et « Noir for Web
/// Apps » ; Safari montre les deux, avec leurs icônes. Une seule est une extension web —
/// l'autre est native, du code compilé que WebKit ne charge que dans Safari. Wuji montrait
/// une ligne, sous le nom de la *mauvaise* moitié : le manifeste de l'extension web ne se
/// nomme que par une clé de localisation, la clé n'était pas résolue, et le repli tombait
/// sur le nom de l'application — c'est-à-dire sur le nom de l'autre segment.
///
/// Trois choses sont vérifiées ici, parce que trois choses ont manqué : le nom est celui
/// que le manifeste déclare, traductions comprises ; ce qui est refusé est **nommé** avec
/// sa raison au lieu de disparaître ; et ce qui ne vise pas le navigateur — widgets,
/// intentions — sort en silence, sans faire passer chaque application pour un échec.
@MainActor
struct ExtensionSegmentTests {

    // MARK: - Un paquet fabriqué pour l'essai

    /// Bâtit une application avec les `.appex` demandés. Rien n'est signé et rien n'a
    /// besoin de l'être : la lecture ne regarde que l'`Info.plist` et le manifeste.
    private func app(_ parts: [(name: String, manifest: String?, point: String?)],
                     locales: [String: String] = [:]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "wuji-segments-\(UUID().uuidString)/Fausse App.app")
        let manager = FileManager.default
        try manager.createDirectory(at: root.appending(path: "Contents"),
                                    withIntermediateDirectories: true)
        try plist(["CFBundleName": "Fausse App"])
            .write(to: root.appending(path: "Contents/Info.plist"), atomically: true, encoding: .utf8)

        for part in parts {
            let appex = root.appending(path: "Contents/PlugIns/\(part.name).appex")
            let resources = appex.appending(path: "Contents/Resources")
            try manager.createDirectory(at: resources, withIntermediateDirectories: true)

            if let point = part.point {
                var info: [String: Any] = ["CFBundleIdentifier": "essai.\(part.name)",
                                           "CFBundleName": "Extension"]
                info["NSExtension"] = ["NSExtensionPointIdentifier": point]
                try plist(info).write(to: appex.appending(path: "Contents/Info.plist"),
                                      atomically: true, encoding: .utf8)
            }
            if let name = part.manifest {
                let manifest = #"{"name":"\#(name)","default_locale":"en","icons":{"128":"i.png"}}"#
                try manifest.write(to: resources.appending(path: "manifest.json"),
                                   atomically: true, encoding: .utf8)
                try Data("PNG".utf8).write(to: resources.appending(path: "i.png"))
            }
            for (key, value) in locales {
                let folder = resources.appending(path: "_locales/en")
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                try #"{"\#(key)":{"message":"\#(value)"}}"#
                    .write(to: folder.appending(path: "messages.json"),
                           atomically: true, encoding: .utf8)
            }
        }
        return root
    }

    /// Un `Info.plist` minimal, écrit à la main pour ne dépendre d'aucun encodeur.
    private func plist(_ values: [String: Any]) -> String {
        func node(_ value: Any) -> String {
            if let table = value as? [String: Any] {
                return "<dict>" + table.map { "<key>\($0.key)</key>" + node($0.value) }
                    .joined() + "</dict>"
            }
            return "<string>\(value)</string>"
        }
        return #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0">"#
            + node(values) + "</plist>"
    }

    // MARK: - Ce que l'on attend

    @Test func leSegmentWebEstPrisEtLeNatifEstNommé() throws {
        let bundle = try app([("Extension", "__MSG_nom__", "com.apple.Safari.web-extension"),
                              ("Mac Extension", nil, "com.apple.Safari.extension")],
                             locales: ["nom": "Fausse App pour le Web"])
        let found = InstalledExtensions.resolve(bundle)

        #expect(found.usable.count == 1)
        // Le nom vient du manifeste **traduit**, et non du repli sur l'application — c'est
        // exactement la confusion qui faisait afficher l'extension web sous le nom du
        // segment natif.
        #expect(found.usable.first?.name == "Fausse App pour le Web")
        #expect(found.rejected.count == 1)
        #expect(found.rejected.first?.reason == .native)
    }

    @Test func leWidgetEtLIntentionSortentEnSilence() throws {
        let bundle = try app([("Extension", "OK", "com.apple.Safari.web-extension"),
                              ("Widget", nil, "com.apple.widgetkit-extension"),
                              ("Intents", nil, "com.apple.intents-service")])
        let found = InstalledExtensions.resolve(bundle)

        #expect(found.usable.count == 1)
        // Rien de refusé : un widget n'est pas une extension que l'on aurait pu prendre, et
        // le signaler ferait passer chaque application pour un ajout à moitié raté.
        #expect(found.rejected.isEmpty)
    }

    @Test func deuxExtensionsDuMêmeNomSeDépartagentParLeurPaquet() throws {
        // Deux manifestes qui se nomment par une clé qu'aucune traduction ne couvre : les
        // deux retombent sur le nom de l'application, et deux lignes identiques ne se
        // départagent plus.
        let bundle = try app([("A", "__MSG_introuvable__", "com.apple.Safari.web-extension"),
                              ("B", "__MSG_introuvable__", "com.apple.Safari.web-extension")])
        let found = InstalledExtensions.resolve(bundle)

        #expect(found.usable.count == 2)
        #expect(Set(found.usable.map(\.name)) == ["Fausse App (A)", "Fausse App (B)"])
    }

    @Test func unManifesteSansPaquetLisibleEstNomméAussi() throws {
        let bundle = try app([("Cassée", "OK", nil)])
        let found = InstalledExtensions.resolve(bundle)

        #expect(found.usable.isEmpty)
        #expect(found.rejected.first?.reason == .unreadable)
    }

    @Test func lIcôneDuManifesteArriveEncodée() throws {
        let bundle = try app([("Extension", "OK", "com.apple.Safari.web-extension")])
        let entry = try #require(InstalledExtensions.resolve(bundle).usable.first)

        #expect(entry.iconFile?.lastPathComponent == "i.png")
        // Une URI de données, parce qu'une page `wuji://` n'a aucun accès au disque — et
        // ne doit pas en recevoir un pour afficher une vignette.
        #expect(InstalledExtensions.iconDataURI(for: entry)?.hasPrefix("data:image/png;base64,")
                == true)
    }
}
