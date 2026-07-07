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
- `roadGraph.lua` — chargement + géométrie du graphe routier : anticipation des feux sur plusieurs segments (`findUpcomingTrafficLight`), filtre anti-trafic-traversant (`isPlausibleLeader`), recherche de segment "sticky" pour la performance (`findNearestSegmentNear`)
- `trafficLights.lua` — lecture de l'état d'un feu ; **échoue en sécurité** (un état illisible est traité comme rouge, jamais comme vert)
- `driverProfile.lua` — personnalité par véhicule (vitesse, distance de suivi, non-respect occasionnel des feux)
- `mobil.lua` — décision de contournement (inspiré MOBIL) : détecte un obstacle proche et quasi à l'arrêt
- `avoidance.lua` — machine à états (idle → contournement → retour) qui gère la durée/l'hystérésis du contournement, pure et testée
- `core.lua` — orchestrateur : au chargement d'une carte pour laquelle un graphe est fourni, charge le graphe et enregistre automatiquement tous les véhicules (et re-scanne toutes les 3s) — aucune commande console requise pour la partie validée
- `data/west_coast_usa.roadgraph.json` — graphe pré-généré, embarqué dans le mod

Chaque appel à l'API du jeu a été vérifié directement dans le code source du jeu installé (`lua/ge/ge_utils.lua`, `lua/ge/extensions/core/vehicles.lua`, `lua/vehicle/ai.lua`, `lua/ge/extensions/core/trafficSignals.lua`) — ce ne sont pas des suppositions.

**Statut** :
- ✅ **Validé en jeu** : suivi de véhicule, respect des feux, bonne vitesse (premier playtest).
- 🔧 **Corrigé depuis, pas encore re-testé** : freinage tardif aux feux, hésitation en tournant à un carrefour, personnalités de conducteurs, performance (scan de segment "sticky") — voir Test 3 ci-dessous.
- 🔁 **Contournement d'obstacle — redesigné après un test qui n'a rien donné.** Premier essai : calculer nous-mêmes un décalage latéral via `ai.laneChange`. Résultat : rien ne bougeait, même en appelant `ai.laneChange` directement, hors de toute logique du mod. En creusant `lua/vehicle/ai.lua`, deux explications : (1) `ai.laneChange` a besoin d'une route active (`currentRoute.plan`) que le jeu vide explicitement quand un véhicule est à l'arrêt près du joueur — exactement le scénario testé ; (2) surtout, **le jeu a déjà son propre évitement latéral natif et continu** (`side_avoidance`, actif dès que `avoidCars='on'`, ce qui est le cas par défaut tant qu'on ne touche pas au mode IA — ce que ce mod ne fait jamais). Nouvelle approche, plus simple et plus fiable : ce mod ne calcule plus de trajectoire, il (1) arrête de traiter l'obstacle comme un arrêt dur pour que le véhicule continue d'avancer, (2) plafonne sa vitesse à une allure prudente (~11 km/h), et (3) augmente temporairement la réactivité de l'évitement natif du jeu (`ai.setParameters({awarenessForceCoef=...})`, confirmé réel) pour qu'il contourne proprement à cette vitesse réduite. Toujours désactivé par défaut — voir Test 4.

### Tests automatisés (hors-jeu)

`idm.lua`, `roadGraph.lua`, `trafficLights.lua`, `driverProfile.lua`, `mobil.lua` et `avoidance.lua` sont du Lua pur (aucune dépendance BeamNG) et testés unitairement avec un interpréteur Lua 5.4 standalone. `core.lua` a un test de fumée qui vérifie qu'il se charge sans erreur de syntaxe et que ses dépendances se résolvent.
```
lua tests/lua/test_idm.lua
lua tests/lua/test_roadGraph.lua
lua tests/lua/test_trafficLights.lua
lua tests/lua/test_driverProfile.lua
lua tests/lua/test_mobil.lua
lua tests/lua/test_avoidance.lua
lua tests/lua/test_core_smoke.lua
```
Tous passent actuellement.

## Installer et tester

**Le dossier utilisateur BeamNG n'est pas forcément `Documents\BeamNG.drive\<version>\`** — ça dépend de l'installation. Sur ce poste, c'est `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\` (confirmé en jeu, via la console : `dump(FS:directoryExists(...))` et le contenu réel de `mods\db.json`). Si le mod n'apparaît pas ou ne se charge pas, vérifie d'abord où vit réellement ton dossier de mods avant de chercher plus loin.

**Format retenu : dossier "unpacked"**, pas zip — un zip déposé dans `mods/` a échoué à se monter dans ce cas précis (raison exacte non identifiée ; le dossier `unpacked` est de toute façon plus simple à mettre à jour et plus fiable). Le mod vit à :
```
%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked\beamai\lua\ge\extensions\beamai\
```
qui doit contenir directement `core.lua`, `idm.lua`, `roadGraph.lua`, `trafficLights.lua`, `driverProfile.lua`, `mobil.lua`, `avoidance.lua` et le sous-dossier `data\` avec `west_coast_usa.roadgraph.json` — c'est-à-dire une copie de `mod/lua/` de ce dépôt vers `mods/unpacked/beamai/lua/`.

Après toute modification du code, il suffit de recopier `mod/lua/*` par-dessus ce dossier (pas besoin de reconstruire un zip).

### Test 3 — les trois corrections précédentes (automatique, comme d'habitude)

1. Lance BeamNG.drive, charge **West Coast, USA**, attends ~5 secondes
2. Observe :
   - **Freinage aux feux** : plus progressif qu'avant, ou encore tardif ?
   - **Carrefours** : un véhicule qui tourne hésite-t-il/panique-t-il encore à cause d'un véhicule qui traverse ?
   - **Personnalités** : des véhicules visiblement plus rapides/lents que d'autres, ou un qui grille un feu ?

**Dis-moi** : toute erreur console (texte exact) · si les trois points sont améliorés · tout comportement bizarre.

### Test 4 — contournement d'obstacle (redesigné, à refaire)

**Important : ne teste pas en étant toi-même l'obstacle à l'arrêt.** Le test précédent (toi arrêté devant/près d'un véhicule IA) tombait justement dans le cas où le jeu désactive sa propre planification de route. Pour un test propre : reste en mouvement ou observe de loin un véhicule IA qui rencontre un obstacle tout seul (un autre véhicule arrêté à un feu, en panne, ou gare-toi puis éloigne-toi à pied/en véhicule avant que l'IA n'approche).

Dans la console Lua (Game Engine) :
```lua
extensions.beamai_core.setAvoidanceEnabled(true)
```

**Dis-moi** :
- Le véhicule ralentit-il à une allure prudente puis continue-t-il à avancer au lieu de s'arrêter net derrière l'obstacle ?
- Le contourne-t-il visiblement (léger déplacement latéral) au lieu de rester bloqué ou de rentrer dedans ?
- Toute erreur console au moment de la manœuvre (texte exact).

### Regénérer le graphe embarqué (rare, seulement si `tools/extract_road_graph.py` change)

```
python tools/extract_road_graph.py "<Steam>/content/levels/west_coast_usa.zip" -o mod/lua/ge/extensions/beamai/data/west_coast_usa.roadgraph.json
```
