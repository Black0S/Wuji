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
            // `json:` — ce que `trusted-set` emploie pour poser autre chose qu'un scalaire.
            if (typeof v === 'string' && v.startsWith('json:')) {
              try { return JSON.parse(v.slice(5)); } catch (_) { return undefined; }
            }
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

      // **Un chemin JSON peut porter des jokers.** Les règles de YouTube écrivent
      // `entries.[-].command.reelWatchEndpoint.adClientParams.isAd` : `[]`, `[-]` et `*`
      // veulent tous dire « n'importe quel élément à ce niveau ». Un lecteur de chemin qui
      // ne saurait que les points laisserait passer la moitié des règles qui comptent.
      const joker = (c) => c === '*' || c === '[]' || c === '[-]';

      const parcourir = (objet, parts, faire) => {
        if (objet === null || typeof objet !== 'object') return;
        if (parts.length === 1) return faire(objet, parts[0]);
        const [tête, ...reste] = parts;
        if (joker(tête)) {
          for (const clé of Object.keys(objet)) parcourir(objet[clé], reste, faire);
        } else if (tête in objet) {
          parcourir(objet[tête], reste, faire);
        }
      };

      const lireChemin = (objet, chemin) => {
        let courant = objet;
        for (const part of chemin.split('.')) {
          if (courant === null || courant === undefined) return undefined;
          if (joker(part)) {
            const clés = Object.keys(courant);
            if (!clés.length) return undefined;
            courant = courant[clés[0]];
          } else {
            courant = courant[part];
          }
        }
        return courant;
      };

      // Rend une fonction qui élague un objet, ou le laisse tel quel si les conditions
      // demandées n'y sont pas : une règle qui exige `playerResponse` ne doit pas toucher
      // à une réponse qui n'en a pas.
      const élagueur = (àRetirer, requis) => {
        const chemins = String(àRetirer || '').split(/\s+/).filter(Boolean);
        const nécessaires = String(requis || '').split(/\s+/).filter(Boolean);
        return (objet) => {
          if (!objet || typeof objet !== 'object' || !chemins.length) return objet;
          if (nécessaires.length
              && !nécessaires.every((c) => lireChemin(objet, c) !== undefined)) return objet;
          for (const chemin of chemins) {
            const parts = chemin.split('.');
            parcourir(objet, parts, (parent, clé) => {
              if (parent && typeof parent === 'object') {
                if (joker(clé)) { for (const k of Object.keys(parent)) delete parent[k]; }
                else delete parent[clé];
              }
            });
          }
          return objet;
        };
      };

      // Les guillemets simples d'une règle ne font pas partie du motif : `'"adPlacements"'`
      // veut dire la chaîne `"adPlacements"`, guillemets doubles compris.
      const dénuder = (t) => {
        const s = String(t === undefined ? '' : t);
        return /^'.*'$/s.test(s) ? s.slice(1, -1) : s;
      };

      // Un motif de remplacement : expression régulière entre barres, ou texte littéral.
      const remplaceur = (motifTexte, remplacement) => {
        const brut = dénuder(motifTexte);
        const vers = dénuder(remplacement);
        if (!brut) return null;
        if (brut.length > 2 && brut.startsWith('/') && brut.lastIndexOf('/') > 0) {
          const fin = brut.lastIndexOf('/');
          try {
            const drapeaux = brut.slice(fin + 1) || 'g';
            const re = new RegExp(brut.slice(1, fin),
                                  drapeaux.includes('g') ? drapeaux : drapeaux + 'g');
            return (texte) => texte.replace(re, vers);
          } catch (_) { return null; }
        }
        return (texte) => texte.split(brut).join(vers);
      };

      // **Réécrire une réponse réseau.** C'est le seul endroit où l'on peut retirer les
      // emplacements publicitaires d'un lecteur qui les reçoit en JSON, après le chargement
      // de la page : ni une règle de blocage ni une feuille de style n'y ont accès.
      //
      // Une tâche par règle, un seul détournement de `fetch` et un seul de `XMLHttpRequest` :
      // dix règles sur la même page ne doivent pas empiler dix couches d'enveloppes.
      const tâchesFetch = [];
      const tâchesXhr = [];
      let fetchPosé = false;
      let xhrPosé = false;

      const poserFetch = () => {
        if (fetchPosé) return;
        fetchPosé = true;
        const original = window.fetch;
        if (typeof original !== 'function') return;
        window.fetch = function (entrée, options) {
          const url = typeof entrée === 'string' ? entrée
                    : (entrée && entrée.url) ? entrée.url : String(entrée);
          const tâches = tâchesFetch.filter((t) => t.teste(url));
          const promesse = original.call(this, entrée, options);
          if (!tâches.length) return promesse;
          return promesse.then((réponse) => {
            if (!réponse || !réponse.ok) return réponse;
            return réponse.clone().text().then((texte) => {
              let sortie = texte;
              for (const t of tâches) { try { sortie = t.changer(sortie); } catch (_) {} }
              if (sortie === texte) return réponse;
              const neuve = new Response(sortie, { status: réponse.status,
                                                   statusText: réponse.statusText,
                                                   headers: réponse.headers });
              // `url` n'est pas copiée par le constructeur, et du code la lit.
              try { Object.defineProperty(neuve, 'url', { value: réponse.url }); } catch (_) {}
              return neuve;
            }).catch(() => réponse);
          });
        };
      };

      // **Une sous-classe, pas un détournement de `send`.** `responseText` est en lecture
      // seule : la seule façon de rendre autre chose est de redéfinir l'accesseur, donc
      // d'hériter. Poser un écouteur dans `send` arriverait après celui de la page.
      const poserXhr = () => {
        if (xhrPosé) return;
        xhrPosé = true;
        const Base = window.XMLHttpRequest;
        if (typeof Base !== 'function') return;
        window.XMLHttpRequest = class extends Base {
          open(méthode, url, ...reste) {
            this.__wujiUrl = String(url);
            return super.open(méthode, url, ...reste);
          }
          __wujiChanger(texte) {
            if (typeof texte !== 'string' || !texte) return texte;
            if (this.__wujiSource === texte) return this.__wujiSortie;
            let sortie = texte;
            for (const t of tâchesXhr) {
              if (!t.teste(this.__wujiUrl || '')) continue;
              try { sortie = t.changer(sortie); } catch (_) {}
            }
            this.__wujiSource = texte;
            this.__wujiSortie = sortie;
            return sortie;
          }
          get responseText() { return this.__wujiChanger(super.responseText); }
          get response() {
            const brut = super.response;
            // Une réponse déjà décodée — `json`, `blob` — n'est pas du texte : on ne
            // prétend pas la réécrire.
            return typeof brut === 'string' ? this.__wujiChanger(brut) : brut;
          }
        };
      };

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

            // **Une fonction reste une fonction.** Remplacer `addEventListener` par un
            // accesseur paraît équivalent — la lecture rend la même chose — mais
            // `Object.getOwnPropertyDescriptor()` rend alors un descripteur sans `value`.
            // Le polyfill Shady DOM de YouTube recopie ce descripteur pour fabriquer
            // `__shady_addEventListener` : il y copiait `undefined`, et la page mourait sur
            // « undefined is not an object ». Mesuré : deux liens vidéo sur l'accueil, puis
            // zéro, et la page restait à son squelette.
            //
            // On enveloppe donc l'appel au lieu de piéger la lecture. L'intention de la
            // règle est tenue — le script en ligne qui correspond est arrêté quand il s'en
            // sert — et rien ne change pour les autres.
            if (typeof gardée === 'function') {
              const original = gardée;
              const enveloppe = function (...args) {
                const texte = courant();
                if (texte !== null && teste(texte)) throw new ReferenceError(clé);
                return original.apply(this, args);
              };
              // Le nom et la signature sont recopiés : un site qui les inspecte ne doit pas
              // découvrir l'enveloppe.
              try {
                Object.defineProperty(enveloppe, 'name', { value: original.name });
                Object.defineProperty(enveloppe, 'length', { value: original.length });
                enveloppe.toString = () => original.toString();
              } catch (_) {}
              try {
                Object.defineProperty(objet, clé, {
                  configurable: true, writable: true, value: enveloppe
                });
              } catch (_) {}
              return;
            }

            try {
              Object.defineProperty(objet, clé, {
                // **`configurable: true`, et c'est tout le correctif.** Cette primitive ne
                // scelle pas une propriété : elle arrête *un* script en ligne et laisse
                // passer tout le monde. La sceller empêchait la page de la redéfinir —
                // `Object.defineProperty` y lève une `TypeError` — et YouTube, qui remplace
                // `EventTarget.prototype.addEventListener` à son démarrage, s'arrêtait là :
                // le squelette s'affichait, les vignettes n'arrivaient jamais. Mesuré, avec
                // les trois règles génériques de la liste d'uBlock : deux liens vidéo sur
                // l'accueil, puis zéro.
                configurable: true,
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

        // --- Réécriture des réponses réseau ---
        //
        // **C'est ce qui bloque les publicités de YouTube.** Les emplacements arrivent dans
        // le JSON de `/youtubei/v1/player`, demandé par `fetch` après le chargement : aucune
        // règle de blocage ne peut le refuser — c'est la même requête qui porte la vidéo —
        // et aucune feuille de style ne le voit. Il faut lire la réponse et en retirer les
        // emplacements avant que le lecteur ne la lise.

        'json-prune-fetch-response': (àRetirer, requis, où) => {
          const élague = élagueur(àRetirer, requis);
          const teste = motif(où);
          poserFetch();
          tâchesFetch.push({ teste, changer: (texte) => {
            const objet = JSON.parse(texte);
            return JSON.stringify(élague(objet));
          } });
        },

        'json-prune-xhr-response': (àRetirer, requis, où) => {
          const élague = élagueur(àRetirer, requis);
          const teste = motif(où);
          poserXhr();
          tâchesXhr.push({ teste, changer: (texte) => {
            const objet = JSON.parse(texte);
            return JSON.stringify(élague(objet));
          } });
        },

        'replace-fetch-response': (motifTexte, remplacement, où) => {
          const changer = remplaceur(motifTexte, remplacement);
          if (!changer) return;
          poserFetch();
          tâchesFetch.push({ teste: motif(où), changer });
        },

        'replace-xhr-response': (motifTexte, remplacement, où) => {
          const changer = remplaceur(motifTexte, remplacement);
          if (!changer) return;
          poserXhr();
          tâchesXhr.push({ teste: motif(où), changer });
        },

        // **Le site ne récupère pas un `fetch` neuf en passant par un cadre.** C'est la
        // parade connue contre le détournement : créer un `<iframe>`, y lire la fonction
        // d'origine que personne n'a touchée, et s'en servir. On repose donc la nôtre dans
        // le cadre au moment où il entre dans le document.
        'trusted-prevent-dom-bypass': (chemin, propriétés) => {
          const noms = String(propriétés || 'fetch').split(/[\s,|]+/).filter(Boolean);
          auBout(window, chemin || 'Node.prototype.appendChild', (objet, clé) => {
            const original = objet[clé];
            if (typeof original !== 'function') return;
            try {
              objet[clé] = function (...args) {
                const rendu = original.apply(this, args);
                try {
                  const noeud = args[0];
                  if (noeud && noeud.tagName === 'IFRAME' && noeud.contentWindow) {
                    for (const nom of noms) {
                      if (window[nom] !== undefined) noeud.contentWindow[nom] = window[nom];
                    }
                  }
                } catch (_) {}
                return rendu;
              };
            } catch (_) {}
          });
        },

        'json-prune': (àRetirer, requis) => {
          if (!String(àRetirer || '').trim()) return;
          const élaguer = élagueur(àRetirer, requis);
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

        // Poser un attribut, comme `remove-attr` mais dans l'autre sens. Souvent employé
        // pour rendre à un lecteur vidéo un attribut qu'une régie lui a retiré.
        'set-attr': (sélecteur, nom, valeur) => {
          if (!sélecteur || !nom) return;
          const v = valeur === undefined ? '' : String(valeur);
          àChaqueChangement(() => {
            for (const el of élémentsDe(sélecteur)) {
              if (el.getAttribute(nom) !== v) el.setAttribute(nom, v);
            }
          });
        },

        // **Le DOM caché d'un composant.** Un encart posé dans une racine fantôme échappe à
        // `querySelectorAll` : il faut descendre dans chaque racine ouverte, une à une.
        // Une racine fermée reste hors de portée — c'est ce que « fermée » veut dire.
        'hide-in-shadow-dom': (sélecteur, base) => {
          if (!sélecteur) return;
          const descendre = (racine, vus) => {
            if (!racine || vus.has(racine)) return;
            vus.add(racine);
            try {
              for (const el of racine.querySelectorAll(sélecteur)) {
                el.style.setProperty('display', 'none', 'important');
              }
            } catch (_) {}
            const enfants = racine.querySelectorAll ? racine.querySelectorAll('*') : [];
            for (const el of enfants) if (el.shadowRoot) descendre(el.shadowRoot, vus);
          };
          àChaqueChangement(() => {
            const départ = base ? élémentsDe(base) : [document];
            const vus = new Set();
            for (const d of départ) descendre(d.shadowRoot || d, vus);
          });
        },

        // Neutraliser une méthode native qu'un site emploie pour se défendre — le plus
        // souvent `Object.defineProperty` ou `Element.attachShadow`. On rend une fonction
        // qui ne fait rien plutôt que de lever : une exception casserait la page.
        'trusted-suppress-native-method': (chemin, signature) => {
          if (!chemin) return;
          const teste = motif(signature);
          auBout(window, chemin, (objet, clé) => {
            const original = objet[clé];
            if (typeof original !== 'function') return;
            try {
              objet[clé] = function (...args) {
                if (teste(args.map((a) => String(a)).join(' '))) return undefined;
                return original.apply(this, args);
              };
            } catch (_) {}
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
