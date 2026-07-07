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

Le mod lui-même (Game Engine Lua) : `idm.lua` (modèle de poursuite), `roadGraph.lua` (chargement/géométrie du graphe routier), `core.lua` (orchestration — contrôle un ensemble explicite de véhicules sur une seule voie, sans intersection ; portée de la phase 1 de la roadmap). `core.lua` n'a pas encore été validé en jeu — voir l'avertissement en tête de fichier.

**Pour tester en jeu** : copier le dossier `mod/lua` dans `Documents/BeamNG.drive/<version>/mods/unpacked/beamai/lua`, lancer le jeu, puis dans la console Lua (Game Engine) :
```lua
extensions.beamai_core.setGraphPath("<chemin vers un .roadgraph.json généré par l'outil ci-dessus>")
extensions.beamai_core.registerVehicle(<id véhicule>)
extensions.beamai_core.setEnabled(true)
```

### Tests

`idm.lua` et `roadGraph.lua` sont du Lua pur (aucune dépendance BeamNG) et testés unitairement avec un interpréteur Lua 5.4 standalone :
```
lua tests/lua/test_idm.lua
lua tests/lua/test_roadGraph.lua
```
`core.lua` dépend de l'API du jeu (`be`, `queueLuaCommand`, `jsonDecode`...) et ne peut être testé qu'en jeu.
