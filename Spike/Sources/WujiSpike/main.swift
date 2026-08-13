import AppKit

// Exécutable SPM plutôt que projet Xcode : le spike est jetable, la boucle `swift run`
// prend quelques secondes, et rien ici ne préjuge de l'arborescence finale (spec §6.1).
// Lancé depuis un bundle, la sortie n'est plus un terminal : `print` passe en mode
// bloc et le journal du spike n'apparaît qu'à la fermeture. Or c'est cette sortie qui
// porte les compteurs de la semaine 3.
setbuf(stdout, nil)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
