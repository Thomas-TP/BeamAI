# BeamAI

Refonte complète de l'IA de circulation pour BeamNG.drive — une IA de trafic qui respecte le code de la route et conduit comme un humain, pas comme un script.

Plan complet et architecture : [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

## Outils

### `tools/extract_road_graph.py`

Extrait un graphe routier sémantique (segments + intersections + feux) directement depuis un fichier `.zip` de carte BeamNG.drive standard — aucune instance du jeu en cours d'exécution requise, aucun BeamNG.tech/BeamNGpy nécessaire pour cette étape.

```
python tools/extract_road_graph.py "<Steam>/steamapps/common/BeamNG.drive/content/levels/west_coast_usa.zip"
```

Produit un fichier `<carte>.roadgraph.json` (segments de route, intersections détectées, feux tricolores appariés). Voir section 4.2 de `docs/ARCHITECTURE.md` pour le schéma complet et les limites connues de cette première passe.

### `mod/lua/ge/extensions/beamai/`

Le mod lui-même (Game Engine Lua) :
- `idm.lua` — modèle de poursuite (contrôle longitudinal)
- `roadGraph.lua` — chargement + géométrie du graphe routier
- `trafficLights.lua` — lecture de l'état d'un feu ; **échoue en sécurité** (un état illisible est traité comme rouge, jamais comme vert)
- `core.lua` — orchestrateur : contrôle un ensemble explicite de véhicules sur une seule voie, avec arrêt aux feux si le segment se termine sur un carrefour à feux (portée de la phase 1 de la roadmap)

Ces quatre fichiers n'ont **pas encore été validés en jeu** — je n'ai pas moyen de lancer BeamNG.drive depuis cet environnement. Voir l'avertissement en tête de `core.lua`.

### Tests automatisés (hors-jeu)

`idm.lua`, `roadGraph.lua` et `trafficLights.lua` sont du Lua pur (aucune dépendance BeamNG) et testés unitairement avec un interpréteur Lua 5.4 standalone. `core.lua` a un test de fumée qui vérifie qu'il se charge sans erreur de syntaxe et que ses dépendances se résolvent.
```
lua tests/lua/test_idm.lua
lua tests/lua/test_roadGraph.lua
lua tests/lua/test_trafficLights.lua
lua tests/lua/test_core_smoke.lua
```
Tous passent actuellement. Ce que ces tests ne couvrent **pas** : tout ce qui touche à l'API réelle du jeu (`be`, `queueLuaCommand`, `ai.setSpeed`, `extensions.core_trafficSignals`, `jsonDecode`) — d'où les deux tests en jeu ci-dessous.

## Tests en jeu à faire — et ce qu'il faut me rapporter

Deux étapes séparées exprès, pour isoler les problèmes : si l'étape 2 échoue mais que l'étape 1 marche, on saura que le souci vient précisément de la lecture des feux et pas du reste.

### Test 1 — la boucle de base (sans feux)

**But** : vérifier que le mod se charge, que le graphe se charge, et qu'un véhicule suit l'autre sans se rapprocher dangereusement — donc que `queueLuaCommand`/`ai.setSpeed` fonctionne vraiment.

1. Génère un graphe sur une carte simple : `python tools/extract_road_graph.py ".../content/levels/gridmap_v2.zip" -o gridmap.roadgraph.json`
2. Copie `mod/lua` dans `Documents/BeamNG.drive/<version>/mods/unpacked/beamai/lua`
3. Charge la carte `gridmap_v2`, va dans la zone `zone_AI_city` (petite ville de test dédiée à l'IA), place-toi sur une route droite avec au moins un autre véhicule devant le tien (spawn-en un si besoin)
4. Console Lua (Game Engine) :
   ```lua
   extensions.beamai_core.setGraphPath("<chemin complet vers gridmap.roadgraph.json>")
   extensions.beamai_core.registerAll()
   extensions.beamai_core.setEnabled(true)
   ```

**Ce qu'il faut me dire** :
- Le texte exact de toute ligne rouge/erreur dans la console à chaque étape (chargement du mod, `setGraphPath`, `registerAll`, `setEnabled`)
- Est-ce que le véhicule suiveur change visiblement de vitesse (accélère/freine) ? Ou rien ne se passe ?
- Est-ce qu'il percute le véhicule de devant, ou s'arrête sans raison ?

### Test 2 — la lecture des feux (seulement si le Test 1 fonctionne)

**But** : vérifier si `extensions.core_trafficSignals` répond à l'une des trois façons devinées dans `trafficLights.lua` (ligne 90+) — sinon l'IA échouera en sécurité et s'arrêtera à **tous** les feux, même verts.

1. Génère le graphe de `west_coast_usa` (contient de vrais feux) et charge-le comme au Test 1, mais sur une route qui débouche sur un carrefour à feux en ville
2. Regarde la console au moment où le véhicule approche du feu

**Ce qu'il faut me dire** :
- Est-ce que ce message apparaît : `could not read live traffic light state (...)` ? (oui/non, et le texte exact si différent)
- Si non (donc la lecture a réussi) : est-ce que le véhicule s'arrête au rouge et repart au vert, **en cohérence avec la couleur affichée sur le vrai feu** ? Ou y a-t-il un décalage ?
- Si oui (le message apparaît) : le véhicule s'arrête-t-il systématiquement avant le carrefour, même quand le feu est vert ? (comportement attendu du mode échec-sécurisé — ça confirme qu'il faut que je corrige `queryLiveState`)
