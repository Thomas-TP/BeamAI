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
- `core.lua` — orchestrateur : au chargement d'une carte pour laquelle un graphe est fourni, charge le graphe et enregistre automatiquement tous les véhicules (et re-scanne toutes les 3s pour les nouveaux venus) — aucune commande console requise
- `data/west_coast_usa.roadgraph.json` — graphe pré-généré, embarqué dans le mod

Chaque appel à l'API du jeu (`be:getObjectCount/getObject/getObjectByID`, `obj:getPosition/getVelocity/getID/queueLuaCommand`, `ai.setSpeed/setSpeedMode`, `extensions.core_trafficSignals.getElementById`, `jsonReadFile`, `path.levelFromPath`) a été vérifié directement dans le code source du jeu installé (`lua/ge/ge_utils.lua`, `lua/ge/extensions/core/vehicles.lua`, `lua/vehicle/ai.lua`, `lua/ge/extensions/core/trafficSignals.lua`) — ce ne sont plus des suppositions. Ce qui reste **non validé** est le comportement une fois en mouvement : est-ce que `pickBestInstance` choisit le bon feu, est-ce que la conduite est crédible, etc. Voir l'avertissement en tête de `core.lua`.

### Tests automatisés (hors-jeu)

`idm.lua`, `roadGraph.lua` et `trafficLights.lua` sont du Lua pur (aucune dépendance BeamNG) et testés unitairement avec un interpréteur Lua 5.4 standalone. `core.lua` a un test de fumée qui vérifie qu'il se charge sans erreur de syntaxe et que ses dépendances se résolvent.
```
lua tests/lua/test_idm.lua
lua tests/lua/test_roadGraph.lua
lua tests/lua/test_trafficLights.lua
lua tests/lua/test_core_smoke.lua
```
Tous passent actuellement.

## Installer et tester — une seule action manuelle

`dist/beamai.zip` est prêt à l'emploi (mod + graphe de `west_coast_usa` déjà généré dedans). Je n'ai pas pu le déposer moi-même dans ton dossier de mods : Windows bloque l'écriture dans `Documents` depuis cet environnement (protection anti-ransomware probable), donc il te faut :

1. Copie `dist/beamai.zip` dans `Documents\BeamNG.drive\0.38\mods\` (crée le dossier `mods` s'il n'existe pas)
2. Lance BeamNG.drive, charge la carte **West Coast, USA**
3. Attends ~5 secondes (le mod se charge, enregistre les véhicules automatiquement) — pas de console à toucher
4. Observe le trafic : les véhicules IA suivent-ils les autres sans les percuter ? S'arrêtent-ils aux feux rouges et repartent-ils au vert ?

**Ce qu'il faut me dire** :
- Toute ligne rouge/erreur dans la console (touche généralement `~` ou l'icône console en bas de l'écran) — copie-colle le texte exact
- Est-ce que les véhicules de circulation semblent suivre une logique différente de d'habitude (accélèrent/freinent en fonction de la voiture devant) ?
- Précisément aux feux : est-ce qu'un véhicule s'arrête au rouge et repart au vert **en cohérence avec la couleur réellement affichée sur le poteau** ? Ou s'arrête-t-il tout le temps (même au vert) ? Ou ignore-t-il le feu ?
- Si tu vois ce message dans la console : `could not read live traffic light state (...)` — dis-le-moi, ça veut dire que `pickBestInstance`/`getElementById` ne trouve pas le bon feu et que je dois corriger.

### Reconstruire le zip après une modification

```
python tools/extract_road_graph.py "<Steam>/content/levels/west_coast_usa.zip" -o mod/lua/ge/extensions/beamai/data/west_coast_usa.roadgraph.json
```
puis compresser le contenu de `mod/` (pas le dossier `mod` lui-même — le zip doit avoir `lua/` à sa racine) en `dist/beamai.zip`.
