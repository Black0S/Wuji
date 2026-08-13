import AppKit

// Exécutable SPM plutôt que projet Xcode : le spike est jetable, la boucle `swift run`
// prend quelques secondes, et rien ici ne préjuge de l'arborescence finale (spec §6.1).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
