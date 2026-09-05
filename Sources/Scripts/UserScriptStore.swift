import Foundation

/// Les scripts utilisateur, sur le disque.
///
/// Un fichier `.user.js` par script, exactement comme on l'a téléchargé, plus un index qui
/// retient l'en-tête analysé et l'état actif. Le fichier reste lisible et modifiable à la
/// main : c'est du code que l'utilisateur fait tourner chez lui, il doit pouvoir le relire.
@MainActor
final class UserScriptStore {

    private(set) var scripts: [UserScript] = []
    var onChange: (() -> Void)?

    private let directory: URL
    private let index: URL
    /// Le corps des scripts, gardé en mémoire.
    ///
    /// **Il était relu sur le disque à chaque navigation.** `matching(_:)` est appelé dans
    /// `decidePolicyFor`, c'est-à-dire sur le chemin critique de chaque page — et sur celui
    /// de chaque changement d'adresse d'un site en une seule page. Une lecture synchrone y
    /// retarde la requête réseau elle-même, pour un fichier qui ne change qu'à
    /// l'installation. Quelques kilo-octets par script : le cache tient dans rien.
    private var bodies: [UUID: String] = [:]

    init(root: URL = Storage.directory) {
        directory = root.appendingPathComponent("userscripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        index = directory.appendingPathComponent("scripts.json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: index),
           let stored = try? decoder.decode([UserScript].self, from: data) {
            scripts = stored
        }
    }

    func code(for script: UserScript) -> String? {
        if let cached = bodies[script.id] { return cached }
        guard let text = try? String(contentsOf: file(for: script), encoding: .utf8) else {
            return nil
        }
        bodies[script.id] = text
        return text
    }

    /// Les scripts actifs qui visent cette adresse.
    func matching(_ url: URL?) -> [(UserScript, String)] {
        guard let url else { return [] }
        return scripts.filter { $0.isEnabled && $0.matches(url) }
            .compactMap { script in code(for: script).map { (script, $0) } }
    }

    @discardableResult
    func add(text: String, source: URL? = nil) -> UserScript? {
        guard text.contains("==UserScript==") || text.count > 20 else { return nil }
        var script = UserScript(text: text, source: source)
        // Une réinstallation remplace, elle n'empile pas : deux fois le même script, c'est
        // deux fois ses effets de bord.
        if let existing = scripts.firstIndex(where: { $0.source == source && source != nil })
            ?? scripts.firstIndex(where: { $0.name == script.name }) {
            script.id = scripts[existing].id
            script.isEnabled = scripts[existing].isEnabled
            scripts[existing] = script
        } else {
            scripts.append(script)
        }
        try? text.write(to: file(for: script), atomically: true, encoding: .utf8)
        bodies[script.id] = text
        save()
        return script
    }

    func setEnabled(_ isEnabled: Bool, id: String?) {
        guard let index = scripts.firstIndex(where: { $0.id.uuidString == id }) else { return }
        scripts[index].isEnabled = isEnabled
        save()
    }

    func remove(id: String?) {
        guard let index = scripts.firstIndex(where: { $0.id.uuidString == id }) else { return }
        try? FileManager.default.removeItem(at: file(for: scripts[index]))
        bodies[scripts[index].id] = nil
        scripts.remove(at: index)
        save()
    }

    private func file(for script: UserScript) -> URL {
        directory.appendingPathComponent("\(script.id.uuidString).user.js")
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(scripts) {
            try? data.write(to: index, options: .atomic)
        }
        onChange?()
    }
}
