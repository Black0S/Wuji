import WebKit

/// Ce que la page dit de ses champs de mot de passe.
///
/// **La page ne décide de rien.** Elle signale qu'un formulaire part avec un mot de passe,
/// et elle sait remplir un champ quand Wuji le lui demande. Tout le reste — quel hôte, quel
/// compte, quel secret — est décidé côté Swift, à partir de l'origine que **WebKit**
/// rapporte et non de celle que la page prétend. C'est la seule protection qui compte ici :
/// sans elle, une page hostile demanderait l'identifiant d'une banque en s'annonçant sous
/// son nom.
@MainActor
enum PasswordForm {

    static let handler = "wujiPassword"

    /// Cadre principal seulement. Un mot de passe saisi dans une `iframe` tierce appartient
    /// à cette tierce partie, pas au site qui l'héberge, et le ranger sous l'hôte de la page
    /// mènerait à le proposer sur le mauvais site.
    static var script: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    private static let source = """
    (() => {
      const CHAMPS_UTILISATEUR = 'input[type=email], input[type=text], input[type=tel], ' +
        'input[name*=user i], input[name*=login i], input[name*=email i], input[id*=user i]';

      const dire = (charge) => {
        try { window.webkit.messageHandlers.wujiPassword.postMessage(charge); }
        catch (error) { /* la page a été démontée */ }
      };

      // Le compte qui va avec ce mot de passe : le champ de saisie le plus proche **avant**
      // lui dans le formulaire. Prendre le premier champ texte de la page attraperait une
      // barre de recherche ; prendre le suivant attraperait un code de vérification.
      const compteDe = (motDePasse) => {
        const cadre = motDePasse.form || document;
        const champs = [...cadre.querySelectorAll(CHAMPS_UTILISATEUR)]
          .filter((c) => c.offsetParent !== null || c.type === 'hidden');
        let candidat = null;
        for (const champ of champs) {
          if (champ.compareDocumentPosition(motDePasse) & Node.DOCUMENT_POSITION_FOLLOWING) {
            candidat = champ;
          }
        }
        return (candidat || champs[0] || {}).value || '';
      };

      const motsDePasse = () => [...document.querySelectorAll('input[type=password]')];

      // --- La complétion ------------------------------------------------------------
      //
      // **Ce qu'on envoie est une position et une amorce, jamais un secret.** Le champ
      // visé donne son rectangle pour que la liste s'ouvre dessous, et le champ de compte
      // donne ce qui y est déjà tapé pour filtrer. La valeur d'un champ de mot de passe ne
      // sort jamais d'ici par cette porte — elle n'a rien à faire dans une complétion.
      let visé = null;

      const estChampDeCompte = (élément) =>
        élément instanceof HTMLInputElement && élément.matches(CHAMPS_UTILISATEUR);
      const estChampSecret = (élément) =>
        élément instanceof HTMLInputElement && élément.type === 'password';

      const proposer = (champ) => {
        if (!champ) return;
        // **Un champ de mot de passe déjà rempli n'a rien à recevoir.** La liste continuait
        // de s'ouvrir par-dessus, proposant d'écrire ce qui était déjà écrit — et il fallait
        // la fermer pour voir le bouton d'envoi qu'elle recouvrait. On referme sans oublier
        // le champ visé : le vider fait revenir la proposition, parce que là elle sert.
        if (estChampSecret(champ) && champ.value) return dire({ action: 'dismiss' });

        const cadre = champ.getBoundingClientRect();
        if (!cadre.width || !cadre.height) return;
        dire({
          action: 'complete',
          // Le champ visé décide de ce qu'un choix remplira : l'un ou l'autre, jamais les
          // deux. On l'annonce ici, une fois, plutôt que de le redeviner au remplissage.
          champ: estChampSecret(champ) ? 'secret' : 'compte',
          amorce: estChampSecret(champ) ? compteDe(champ) : (champ.value || ''),
          x: cadre.left, y: cadre.top, largeur: cadre.width, hauteur: cadre.height
        });
      };

      const fermer = () => { visé = null; dire({ action: 'dismiss' }); };

      // **Une connexion en deux étapes n'a pas de champ de mot de passe.** Google,
      // Microsoft et beaucoup d'autres demandent l'adresse d'abord, sur une page où
      // `input[type=password]` n'existe pas encore. Exiger un champ de mot de passe dans le
      // DOM privait donc de complétion exactement les sites où l'on s'en sert le plus.
      //
      // Ce qui remplace la preuve manquante : la déclaration du champ lui-même. Un champ
      // qui annonce `autocomplete="username"` ou `"email"` dit ce qu'il attend — c'est la
      // même annonce que les gestionnaires de mots de passe lisent, et une barre de
      // recherche ne la porte pas.
      const seDéclareCompte = (champ) => {
        const annonce = (champ.getAttribute('autocomplete') || '').toLowerCase();
        return annonce.split(' ').some((mot) => mot === 'username' || mot === 'email');
      };

      document.addEventListener('focusin', (event) => {
        const champ = event.target;
        if (!estChampDeCompte(champ) && !estChampSecret(champ)) return fermer();
        // Un champ de compte seul ne suffit pas : une barre de recherche en est un aussi.
        // Il faut un mot de passe quelque part sur la page, ou un champ qui s'annonce.
        if (!motsDePasse().length && !seDéclareCompte(champ)) return fermer();
        visé = champ;
        proposer(champ);
      }, true);

      document.addEventListener('focusout', (event) => {
        if (event.target === visé) fermer();
      }, true);

      document.addEventListener('input', (event) => {
        if (event.target !== visé) return;
        proposer(visé);
      }, true);

      // Une liste ancrée à un champ qui bouge pointe le vide : on la referme plutôt que de
      // la faire courir après la page.
      const suivre = () => { if (visé) fermer(); };
      window.addEventListener('scroll', suivre, { capture: true, passive: true });
      window.addEventListener('resize', suivre, { passive: true });

      // Wuji remplit depuis la liste : il faut alors la refermer et rendre la main.
      window.__wujiCompletionFermée = () => { visé = null; };

      // **Après un déverrouillage, la liste doit se rouvrir sans qu'on reclique.** La
      // feuille du mot de passe maître prend le clavier : le champ perd le focus, la page
      // referme, et au retour rien ne se repose la question — on venait pourtant d'ouvrir
      // le coffre exprès. Wuji rappelle donc ce point d'entrée quand il a fini.
      window.__wujiCompletionRelance = () => {
        const champ = document.activeElement;
        if (!(champ instanceof HTMLInputElement)) return false;
        if (!estChampDeCompte(champ) && !estChampSecret(champ)) return false;
        visé = champ;
        proposer(champ);
        return true;
      };

      // **On écoute la soumission en phase de capture.** Un site qui appelle
      // `preventDefault` pour envoyer lui-même en arrière-plan — la moitié du web — ne
      // laisserait rien passer autrement, et l'offre d'enregistrement n'arriverait jamais.
      document.addEventListener('submit', (event) => {
        const dans = event.target.querySelectorAll ?
          [...event.target.querySelectorAll('input[type=password]')] : [];
        const champ = dans.find((c) => c.value) || motsDePasse().find((c) => c.value);
        if (!champ) return;
        dire({ action: 'save', user: compteDe(champ), password: champ.value });
      }, true);

      // Le cas des connexions sans formulaire : un bouton, un `fetch`, et la page change
      // d'adresse. On signale au départ, ce qui couvre les deux.
      window.addEventListener('pagehide', () => {
        const champ = motsDePasse().find((c) => c.value);
        if (champ) dire({ action: 'save', user: compteDe(champ), password: champ.value });
      });

      // Wuji remplit, la page ne demande rien : c'est lui qui appelle ceci quand il a
      // quelque chose à proposer pour cette origine.
      // `portée` vaut `'compte'`, `'secret'`, ou rien pour les deux.
      //
      // **Cliquer dans un champ ne remplit que ce champ.** Poser les deux valeurs d'un coup
      // écrasait un identifiant déjà saisi quand on ne venait chercher que le mot de passe,
      // et posait le secret dans une page qui n'en demandait pas encore — sur une connexion
      // en deux étapes, il n'y a même pas de champ pour le recevoir.
      window.__wujiFill = (user, password, portée) => {
        const secrets = motsDePasse();
        const champ = secrets.find((c) => c.offsetParent !== null) || secrets[0];
        // **Il peut n'y avoir aucun champ de mot de passe, et ce n'est pas un échec.** Une
        // connexion en deux étapes demande l'adresse d'abord ; abandonner ici rendait la
        // complétion muette exactement là où elle venait d'apparaître — la liste s'ouvrait,
        // on choisissait, et rien ne s'écrivait.
        const cadre = (champ && champ.form) || (visé && visé.form) || document;
        const compte = [...cadre.querySelectorAll(CHAMPS_UTILISATEUR)]
          .find((c) => c.offsetParent !== null)
          || (visé && estChampDeCompte(visé) ? visé : null);
        if (!champ && !compte) return false;
        // `input` et `change` sont émis à la main : un cadre qui suit ses champs — React,
        // Vue — ne verrait rien d'une valeur posée directement, et le renverrait vide.
        const poser = (élément, valeur) => {
          const propriété = Object.getOwnPropertyDescriptor(
            Object.getPrototypeOf(élément), 'value');
          propriété && propriété.set ? propriété.set.call(élément, valeur)
                                     : (élément.value = valeur);
          élément.dispatchEvent(new Event('input', { bubbles: true }));
          élément.dispatchEvent(new Event('change', { bubbles: true }));
        };
        if (portée !== 'secret' && compte && user) poser(compte, user);
        if (portée !== 'compte' && champ && password) poser(champ, password);
        return true;
      };

      // À l'arrivée, on annonce simplement qu'il y a un champ à remplir. L'hôte, Wuji le
      // connaît déjà — il vient de WebKit, pas de nous.
      if (motsDePasse().length) dire({ action: 'ask' });
    })();
    """

    /// Ce qu'un remplissage touche.
    ///
    /// **Un champ à la fois, parce que c'est un champ qu'on a désigné.** Cliquer dans
    /// l'identifiant pour se voir écrire aussi le mot de passe, c'est recevoir plus que ce
    /// qu'on a demandé — et le mot de passe n'a alors même pas quitté le trousseau : Wuji
    /// ne va le chercher que pour la portée qui le réclame.
    enum Field: String {
        case account = "compte"
        case secret = "secret"
        /// Le remplissage d'un seul geste : l'automatique à l'arrivée, et « Remplir avec… »
        /// dans le menu du cadenas, qui désigne la connexion entière et non un champ.
        case both = "tout"
    }

    /// L'appel qui remplit, construit côté Swift pour que rien de ce qui vient du trousseau
    /// ne transite par une concaténation approximative.
    static func fill(user: String = "", password: String = "",
                     field: Field = .both) -> String {
        let encode: (String) -> String = { value in
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let text = String(data: data, encoding: .utf8) else { return "\"\"" }
            return String(text.dropFirst().dropLast())
        }
        return "window.__wujiFill && window.__wujiFill("
            + "\(encode(user)), \(encode(password)), \(encode(field.rawValue)))"
    }
}
