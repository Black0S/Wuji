import Foundation

/// Les primitives, écrites une fois.
///
/// **Elles se ressemblent toutes par un point : elles ne cassent jamais la page.** Chaque
/// geste est enveloppé par l'appelant, et chacun ici préfère ne rien faire à faire à moitié.
/// Une primitive qui lèverait sur un site mal formé arrêterait toutes les suivantes, et
/// c'est le genre de panne qu'on ne relie jamais à sa cause.
extension Scriptlets {

    static let library = #"""
      // --- Outils communs ---

      // Un motif de liste est soit `/expression/drapeaux`, soit un texte à chercher tel
      // quel. Le distinguer ici évite de le refaire dans chaque primitive.
      const motif = (source) => {
        if (source === undefined || source === '' || source === '*') return () => true;
        let négation = false;
        if (source.startsWith('!')) { négation = true; source = source.slice(1); }
        let test;
        if (source.length > 2 && source.startsWith('/') && source.lastIndexOf('/') > 0) {
          const fin = source.lastIndexOf('/');
          try {
            const re = new RegExp(source.slice(1, fin), source.slice(fin + 1));
            test = (t) => re.test(t);
          } catch (_) { test = (t) => String(t).includes(source); }
        } else {
          test = (t) => String(t).includes(source);
        }
        return négation ? (t) => !test(t) : test;
      };

      // Les valeurs que `set-constant` sait poser. Une valeur hors de cette liste n'est pas
      // devinée : une liste qui demande autre chose demande du code, pas une constante.
      const valeur = (v) => {
        switch (v) {
          case 'undefined': return undefined;
          case 'null': return null;
          case 'true': return true;
          case 'false': return false;
          case '': case "''": case '""': return '';
          case 'noopFunc': return function () {};
          case 'trueFunc': return function () { return true; };
          case 'falseFunc': return function () { return false; };
          case 'noopPromiseResolve': return function () { return Promise.resolve(); };
          case 'noopPromiseReject': return function () { return Promise.reject(); };
          case 'emptyObj': return {};
          case 'emptyArr': return [];
          case 'noopArray': return [];
          case 'noopStr': return '';
          case 'yes': return 'yes';
          case 'no': return 'no';
          default: {
            const n = Number(v);
            return Number.isNaN(n) ? v : n;
          }
        }
      };

      // Poser une propriété au bout d'un chemin — `a.b.c` — même quand les objets
      // intermédiaires n'existent pas encore : on piège alors l'intermédiaire pour reposer
      // le piège au moment où la page le crée. Sans cela, la moitié des règles arriveraient
      // trop tôt et ne feraient rien.
      const auBout = (racine, chemin, poser) => {
        const parts = chemin.split('.');
        const dernier = parts.pop();
        const descendre = (objet, reste) => {
          if (!reste.length) return poser(objet, dernier);
          const clé = reste[0];
          const suite = reste.slice(1);
          const existant = objet[clé];
          if (existant !== undefined && existant !== null) return descendre(existant, suite);
          let valeurCachée = existant;
          try {
            Object.defineProperty(objet, clé, {
              configurable: true,
              get() { return valeurCachée; },
              set(v) { valeurCachée = v; if (v) { try { descendre(v, suite); } catch (_) {} } }
            });
          } catch (_) {}
        };
        try { descendre(racine, parts); } catch (_) {}
      };

      const constante = (objet, clé, v) => {
        try {
          Object.defineProperty(objet, clé, {
            configurable: false, get() { return v; }, set() {}
          });
        } catch (_) {}
      };

      // Beaucoup de primitives agissent sur des éléments qui n'existent pas au chargement.
      // Un seul observateur pour toutes, débrayé dès qu'il n'a plus rien à faire : un
      // observateur par règle sur une page qui en porte trente coûterait trente fois.
      const àChaqueChangement = (() => {
        const abonnés = new Set();
        let observateur = null;
        let prévu = false;
        const passer = () => {
          prévu = false;
          for (const f of abonnés) { try { f(); } catch (_) {} }
        };
        // **Une image *ou* un délai, le premier qui vient.** Grouper sur une image évite de repasser à chaque nœud ajouté — une page qui écrit son DOM en
        // boucle en produit des centaines par seconde. Mais une page masquée n'a pas
        // d'images : l'onglet d'arrière-plan, la fenêtre réduite, l'aperçu qui n'est pas
        // affiché. Mesuré : rien ne se déclenchait du tout dans ce cas. Les deux sont donc
        // armés, et le drapeau fait que le second arrivé ne travaille pas deux fois.
        const planifier = () => {
          if (prévu) return;
          prévu = true;
          requestAnimationFrame(passer);
          setTimeout(passer, 50);
        };
        return (f) => {
          abonnés.add(f);
          try { f(); } catch (_) {}
          if (!observateur) {
            observateur = new MutationObserver(planifier);
            const démarrer = () => {
              observateur.observe(document.documentElement || document,
                                  { childList: true, subtree: true, attributes: true });
              planifier();
            };
            if (document.documentElement) démarrer();
            else document.addEventListener('DOMContentLoaded', démarrer, { once: true });
            document.addEventListener('DOMContentLoaded', planifier, { once: true });
          }
        };
      })();

      const élémentsDe = (sélecteur) => {
        try { return [...document.querySelectorAll(sélecteur)]; } catch (_) { return []; }
      };

      // --- Les primitives ---

      const bibliothèque = {

        'set-constant': (chemin, v) => {
          const val = valeur(v);
          auBout(window, chemin, (objet, clé) => constante(objet, clé, val));
        },

        'set-cookie': (nom, v, chemin) => {
          const morceaux = [encodeURIComponent(nom) + '=' + encodeURIComponent(v ?? ''),
                            'path=' + (chemin || '/')];
          document.cookie = morceaux.join('; ');
        },

        'set-cookie-reload': (nom, v, chemin) => {
          const déjà = document.cookie.split('; ')
            .some((c) => c.startsWith(encodeURIComponent(nom) + '='));
          bibliothèque['set-cookie'](nom, v, chemin);
          // Une seule fois : recharger en boucle est pire que la bannière qu'on enlève.
          if (!déjà && !window.__wujiCookieRechargé) {
            window.__wujiCookieRechargé = true;
            location.reload();
          }
        },

        'remove-cookie': (m) => {
          const teste = motif(m);
          const jeter = () => {
            for (const paire of document.cookie.split('; ')) {
              const nom = paire.split('=')[0];
              if (!nom || !teste(nom)) continue;
              for (const chemin of ['/', location.pathname]) {
                document.cookie = nom + '=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=' + chemin;
              }
            }
          };
          jeter();
          window.addEventListener('beforeunload', jeter);
        },

        'set-local-storage-item': (clé, v) => {
          try { localStorage.setItem(clé, String(valeur(v) ?? '')); } catch (_) {}
        },

        'set-session-storage-item': (clé, v) => {
          try { sessionStorage.setItem(clé, String(valeur(v) ?? '')); } catch (_) {}
        },

        'abort-on-property-read': (chemin) => {
          auBout(window, chemin, (objet, clé) => {
            try {
              Object.defineProperty(objet, clé, {
                configurable: false,
                get() { throw new ReferenceError(clé); },
                set() {}
              });
            } catch (_) {}
          });
        },

        'abort-on-property-write': (chemin) => {
          auBout(window, chemin, (objet, clé) => {
            let gardée = objet[clé];
            try {
              Object.defineProperty(objet, clé, {
                configurable: false,
                get() { return gardée; },
                set() { throw new ReferenceError(clé); }
              });
            } catch (_) {}
          });
        },

        // Le script en ligne qui lit la propriété est arrêté ; les autres lecteurs passent.
        // C'est toute la différence avec `abort-on-property-read`, et c'est ce qui permet
        // de désarmer un mur anti-bloqueur sans casser le reste de la page.
        'abort-current-inline-script': (chemin, recherche) => {
          const teste = motif(recherche);
          auBout(window, chemin, (objet, clé) => {
            let gardée = objet[clé];
            const courant = () => {
              const el = document.currentScript;
              return el && el.tagName === 'SCRIPT' && !el.src ? (el.textContent || '') : null;
            };
            try {
              Object.defineProperty(objet, clé, {
                configurable: false,
                get() {
                  const texte = courant();
                  if (texte !== null && teste(texte)) throw new ReferenceError(clé);
                  return gardée;
                },
                set(v) {
                  const texte = courant();
                  if (texte !== null && teste(texte)) throw new ReferenceError(clé);
                  gardée = v;
                }
              });
            } catch (_) {}
          });
        },

        'abort-on-stack-trace': (chemin, pile) => {
          const teste = motif(pile);
          auBout(window, chemin, (objet, clé) => {
            let gardée = objet[clé];
            try {
              Object.defineProperty(objet, clé, {
                configurable: false,
                get() {
                  if (teste(new Error().stack || '')) throw new ReferenceError(clé);
                  return gardée;
                },
                set(v) { gardée = v; }
              });
            } catch (_) {}
          });
        },

        'prevent-addEventListener': (type, m) => {
          const testeType = motif(type);
          const testeCode = motif(m);
          const original = EventTarget.prototype.addEventListener;
          EventTarget.prototype.addEventListener = function (t, f, ...reste) {
            try {
              if (testeType(t) && testeCode(String(f))) return;
            } catch (_) {}
            return original.call(this, t, f, ...reste);
          };
        },

        'prevent-setTimeout': (m, délai) => {
          const teste = motif(m);
          const attendu = délai === undefined || délai === '' ? null : Number(délai);
          const original = window.setTimeout;
          window.setTimeout = function (f, d, ...reste) {
            if (teste(String(f)) && (attendu === null || attendu === Number(d))) return 0;
            return original.call(window, f, d, ...reste);
          };
        },

        'prevent-setInterval': (m, délai) => {
          const teste = motif(m);
          const attendu = délai === undefined || délai === '' ? null : Number(délai);
          const original = window.setInterval;
          window.setInterval = function (f, d, ...reste) {
            if (teste(String(f)) && (attendu === null || attendu === Number(d))) return 0;
            return original.call(window, f, d, ...reste);
          };
        },

        'adjust-setTimeout': (m, délai, facteur) => {
          const teste = motif(m);
          const attendu = délai === undefined || délai === '' ? 1000 : Number(délai);
          const coef = facteur === undefined || facteur === '' ? 0.02 : Number(facteur);
          const original = window.setTimeout;
          window.setTimeout = function (f, d, ...reste) {
            const nouveau = teste(String(f)) && Number(d) === attendu ? d * coef : d;
            return original.call(window, f, nouveau, ...reste);
          };
        },

        'adjust-setInterval': (m, délai, facteur) => {
          const teste = motif(m);
          const attendu = délai === undefined || délai === '' ? 1000 : Number(délai);
          const coef = facteur === undefined || facteur === '' ? 0.02 : Number(facteur);
          const original = window.setInterval;
          window.setInterval = function (f, d, ...reste) {
            const nouveau = teste(String(f)) && Number(d) === attendu ? d * coef : d;
            return original.call(window, f, nouveau, ...reste);
          };
        },

        'prevent-window-open': (m) => {
          const teste = motif(m);
          const original = window.open;
          window.open = function (url, ...reste) {
            if (teste(String(url))) return null;
            return original.call(window, url, ...reste);
          };
        },

        'prevent-fetch': (props) => {
          const teste = motif(props);
          const original = window.fetch;
          if (typeof original !== 'function') return;
          window.fetch = function (entrée, options) {
            const url = typeof entrée === 'string' ? entrée : (entrée && entrée.url) || '';
            if (teste(url)) {
              return Promise.resolve(new Response('', { status: 200, statusText: 'OK' }));
            }
            return original.call(window, entrée, options);
          };
        },

        'prevent-xhr': (props) => {
          const teste = motif(props);
          const ouvrir = XMLHttpRequest.prototype.open;
          const envoyer = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function (méthode, url, ...reste) {
            this.__wujiBloqué = teste(String(url));
            return ouvrir.call(this, méthode, url, ...reste);
          };
          XMLHttpRequest.prototype.send = function (...reste) {
            if (!this.__wujiBloqué) return envoyer.apply(this, reste);
            // On rend une réponse vide plutôt que d'échouer : une page qui attend un
            // `load` resterait sinon bloquée sur son écran d'attente.
            Object.defineProperty(this, 'readyState', { value: 4, configurable: true });
            Object.defineProperty(this, 'status', { value: 200, configurable: true });
            Object.defineProperty(this, 'responseText', { value: '', configurable: true });
            Object.defineProperty(this, 'response', { value: '', configurable: true });
            setTimeout(() => {
              this.dispatchEvent(new Event('readystatechange'));
              this.dispatchEvent(new Event('load'));
              this.dispatchEvent(new Event('loadend'));
            }, 1);
          };
        },

        'prevent-eval-if': (m) => {
          const teste = motif(m);
          const original = window.eval;
          window.eval = function (code) {
            if (teste(String(code))) return undefined;
            return original.call(window, code);
          };
        },

        'prevent-element-src-loading': (balise, m) => {
          const teste = motif(m);
          const cible = String(balise || '').toUpperCase();
          const descripteur = (proto) => Object.getOwnPropertyDescriptor(proto, 'src');
          for (const proto of [HTMLScriptElement.prototype, HTMLImageElement.prototype,
                               HTMLIFrameElement.prototype]) {
            const d = descripteur(proto);
            if (!d || !d.set) continue;
            try {
              Object.defineProperty(proto, 'src', {
                configurable: true,
                get() { return d.get.call(this); },
                set(v) {
                  if ((!cible || this.tagName === cible) && teste(String(v))) return;
                  d.set.call(this, v);
                }
              });
            } catch (_) {}
          }
        },

        // Le piège des scripts « BlockAdblock » : ils se relancent par `eval` d'un code
        // qui se reconnaît à sa signature. On les laisse se déclarer et on ne les rejoue pas.
        'prevent-bab': () => {
          const signature = /\.bab_elementid.|getElementById\('babasbmsgx'\)/;
          const original = window.eval;
          window.eval = function (code) {
            if (signature.test(String(code))) return undefined;
            return original.call(window, code);
          };
          const st = window.setTimeout;
          window.setTimeout = function (f, d, ...reste) {
            if (/adsBySasquatch|babasbm/.test(String(f))) return 0;
            return st.call(window, f, d, ...reste);
          };
        },

        'remove-attr': (attributs, sélecteur) => {
          const noms = String(attributs || '').split(/[|,]/).map((a) => a.trim()).filter(Boolean);
          if (!noms.length) return;
          const cible = sélecteur || noms.map((n) => '[' + n + ']').join(',');
          àChaqueChangement(() => {
            for (const el of élémentsDe(cible)) {
              for (const nom of noms) el.removeAttribute(nom);
            }
          });
        },

        'remove-class': (classes, sélecteur) => {
          const noms = String(classes || '').split(/[|,]/).map((c) => c.trim()).filter(Boolean);
          if (!noms.length) return;
          const cible = sélecteur || noms.map((c) => '.' + CSS.escape(c)).join(',');
          àChaqueChangement(() => {
            for (const el of élémentsDe(cible)) el.classList.remove(...noms);
          });
        },

        'remove-node-text': (balise, m) => {
          const teste = motif(m);
          const cible = String(balise || '*');
          àChaqueChangement(() => {
            let éléments;
            if (cible === '#text') {
              const marcheur = document.createTreeWalker(document.body || document,
                                                         NodeFilter.SHOW_TEXT);
              éléments = [];
              let n;
              while ((n = marcheur.nextNode())) éléments.push(n);
            } else {
              éléments = élémentsDe(cible);
            }
            for (const el of éléments) {
              const texte = el.textContent || '';
              if (texte && teste(texte)) el.remove ? el.remove() : (el.textContent = '');
            }
          });
        },

        'replace-node-text': (balise, m, remplacement) => {
          const teste = motif(m);
          const cible = String(balise || '*');
          let re = null;
          if (typeof m === 'string' && m.startsWith('/') && m.lastIndexOf('/') > 0) {
            const fin = m.lastIndexOf('/');
            try { re = new RegExp(m.slice(1, fin), m.slice(fin + 1) || 'g'); } catch (_) {}
          }
          àChaqueChangement(() => {
            for (const el of élémentsDe(cible)) {
              const texte = el.textContent || '';
              if (!texte || !teste(texte)) continue;
              el.textContent = re ? texte.replace(re, remplacement ?? '')
                                  : texte.split(m).join(remplacement ?? '');
            }
          });
        },

        'json-prune': (àRetirer, requis) => {
          const chemins = String(àRetirer || '').split(/\s+/).filter(Boolean);
          const nécessaires = String(requis || '').split(/\s+/).filter(Boolean);
          if (!chemins.length) return;
          const lire = (objet, chemin) => chemin.split('.').reduce(
            (o, c) => (o === undefined || o === null ? o : o[c]), objet);
          const élaguer = (objet) => {
            if (!objet || typeof objet !== 'object') return objet;
            if (nécessaires.length
                && !nécessaires.every((c) => lire(objet, c) !== undefined)) return objet;
            for (const chemin of chemins) {
              const parts = chemin.split('.');
              const clé = parts.pop();
              const parent = parts.reduce(
                (o, c) => (o === undefined || o === null ? o : o[c]), objet);
              if (parent && typeof parent === 'object') delete parent[clé];
            }
            return objet;
          };
          const analyser = JSON.parse;
          JSON.parse = function (...reste) { return élaguer(analyser.apply(this, reste)); };
          if (window.Response && Response.prototype.json) {
            const json = Response.prototype.json;
            Response.prototype.json = function (...reste) {
              return json.apply(this, reste).then(élaguer);
            };
          }
        },

        // Un lien qui passe par un redirecteur porte sa vraie destination dans un
        // paramètre : on la remet à sa place plutôt que de laisser le détour compter la
        // visite.
        'href-sanitizer': (sélecteur, source) => {
          const où = source || '?';
          àChaqueChangement(() => {
            for (const el of élémentsDe(sélecteur || 'a[href]')) {
              const href = el.getAttribute('href');
              if (!href) continue;
              let cible = null;
              if (où === 'text') cible = (el.textContent || '').trim();
              else if (où.startsWith('?')) {
                try { cible = new URL(href, location.href).searchParams.get(où.slice(1)); }
                catch (_) {}
              } else if (où.startsWith('[')) {
                cible = el.getAttribute(où.slice(1, -1));
              }
              if (!cible) continue;
              try {
                const propre = new URL(cible, location.href);
                if (/^https?:$/.test(propre.protocol) && propre.href !== href) {
                  el.setAttribute('href', propre.href);
                }
              } catch (_) {}
            }
          });
        },

        'click-element': (sélecteur) => {
          if (!sélecteur) return;
          const cliqués = new WeakSet();
          àChaqueChangement(() => {
            for (const el of élémentsDe(sélecteur)) {
              if (cliqués.has(el)) continue;
              cliqués.add(el);
              try { el.click(); } catch (_) {}
            }
          });
        },

        'nowebrtc': () => {
          for (const nom of ['RTCPeerConnection', 'webkitRTCPeerConnection']) {
            if (typeof window[nom] !== 'function') continue;
            const remplacement = function () { throw new ReferenceError(nom); };
            remplacement.prototype = { close() {}, createDataChannel() {}, createOffer() {},
                                       setRemoteDescription() {} };
            try { window[nom] = remplacement; } catch (_) {}
          }
        },

        // `log` existe dans les listes pour déboguer une règle. Chez nous elle ne fait
        // rien : écrire dans la console d'une page qu'on n'a pas ouverte pour ça
        // n'apprendrait rien à personne.
        'log': () => {}
      };
    """#
}
