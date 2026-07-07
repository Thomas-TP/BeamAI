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
- `roadGraph.lua` — chargement + géométrie du graphe routier : anticipation des feux sur plusieurs segments (`findUpcomingTrafficLight`), filtre anti-trafic-traversant (`isPlausibleLeader`), vérification de dégagement latéral (`isOffsetPathClear`)
- `trafficLights.lua` — lecture de l'état d'un feu ; **échoue en sécurité** (un état illisible est traité comme rouge, jamais comme vert)
- `driverProfile.lua` — personnalité par véhicule (vitesse, distance de suivi, non-respect occasionnel des feux)
- `mobil.lua` — décision d'esquive/dépassement (inspiré MOBIL)
- `avoidance.lua` — machine à états de la manœuvre latérale (idle → décalage → retour), pure et testée, indépendante de l'exécution réelle
- `core.lua` — orchestrateur : au chargement d'une carte pour laquelle un graphe est fourni, charge le graphe et enregistre automatiquement tous les véhicules (et re-scanne toutes les 3s) — aucune commande console requise pour la partie validée
- `data/west_coast_usa.roadgraph.json` — graphe pré-généré, embarqué dans le mod

Chaque appel à l'API du jeu a été vérifié directement dans le code source du jeu installé (`lua/ge/ge_utils.lua`, `lua/ge/extensions/core/vehicles.lua`, `lua/vehicle/ai.lua`, `lua/ge/extensions/core/trafficSignals.lua`) — ce ne sont pas des suppositions, y compris `ai.laneChange` (existe, confirmé, borné à la largeur de route par le jeu lui-même).

**Statut** :
- ✅ **Validé en jeu** : suivi de véhicule, respect des feux, bonne vitesse (premier playtest).
- 🔧 **Corrigé depuis, pas encore re-testé** : freinage tardif aux feux, hésitation en tournant à un carrefour, personnalités de conducteurs — voir Test 3 ci-dessous.
- 🧪 **Expérimental, désactivé par défaut** : esquive latérale d'obstacle (phase 3). La logique de décision est testée à fond ; seul l'appel réel à `ai.laneChange` n'a jamais tourné en jeu. Voir Test 4, à faire **isolément** avant d'activer en circulation dense.

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

## Installer et tester — une seule action manuelle

`dist/beamai.zip` a été reconstruit. Remplace l'ancien dans `Documents\BeamNG.drive\0.38\mods\` (même nom, il suffit d'écraser).

### Test 3 — les trois corrections précédentes (automatique, comme d'habitude)

1. Lance BeamNG.drive, charge **West Coast, USA**, attends ~5 secondes
2. Observe :
   - **Freinage aux feux** : plus progressif qu'avant, ou encore tardif ?
   - **Carrefours** : un véhicule qui tourne hésite-t-il/panique-t-il encore à cause d'un véhicule qui traverse ?
   - **Personnalités** : des véhicules visiblement plus rapides/lents que d'autres, ou un qui grille un feu ?

**Dis-moi** : toute erreur console (texte exact) · si les trois points sont améliorés · tout comportement bizarre.

### Test 4 — esquive d'obstacle (expérimental, à faire à part)

Ne l'active pas en pleine ville tout de suite : commence isolé. Place-toi (ou un véhicule IA) sur une route droite et calme avec un seul autre véhicule à l'arrêt devant, pas de circulation autour.

Dans la console Lua (Game Engine) :
```lua
extensions.beamai_core.setAvoidanceEnabled(true)
```
(le reste — chargement du graphe, `setEnabled` — est déjà automatique sur West Coast USA)

**Dis-moi** :
- Le véhicule tente-t-il de contourner l'obstacle à l'arrêt, ou reste-t-il bloqué derrière comme avant ?
- **De quel côté part-il** (gauche ou droite) ? Le sens n'est pas encore confirmé — si c'est le mauvais côté (vers la circulation venant en face plutôt que vers le côté dégagé), dis-le-moi, c'est un seul signe à inverser dans le code.
- Revient-il proprement sur sa voie après ? Est-ce fluide ou saccadé ?
- Si un autre véhicule est présent à proximité pendant la manœuvre : l'évite-t-il, ou fonce-t-il dedans ? (teste ce cas seulement après avoir validé le cas isolé)
- Toute erreur console au moment de la manœuvre (texte exact).

### Reconstruire le zip après une modification

```
python tools/extract_road_graph.py "<Steam>/content/levels/west_coast_usa.zip" -o mod/lua/ge/extensions/beamai/data/west_coast_usa.roadgraph.json
```
puis compresser le contenu de `mod/` (pas le dossier `mod` lui-même — le zip doit avoir `lua/` à sa racine) en `dist/beamai.zip`.
