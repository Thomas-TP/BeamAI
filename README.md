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
- `roadGraph.lua` — chargement + géométrie du graphe routier, dont l'anticipation des feux sur plusieurs segments (`findUpcomingTrafficLight`) et le filtre anti-trafic-traversant (`isPlausibleLeader`)
- `trafficLights.lua` — lecture de l'état d'un feu ; **échoue en sécurité** (un état illisible est traité comme rouge, jamais comme vert)
- `driverProfile.lua` — personnalité par véhicule (vitesse, distance de suivi, non-respect occasionnel des feux)
- `core.lua` — orchestrateur : au chargement d'une carte pour laquelle un graphe est fourni, charge le graphe et enregistre automatiquement tous les véhicules (et re-scanne toutes les 3s pour les nouveaux venus) — aucune commande console requise
- `data/west_coast_usa.roadgraph.json` — graphe pré-généré, embarqué dans le mod

Chaque appel à l'API du jeu a été vérifié directement dans le code source du jeu installé (`lua/ge/ge_utils.lua`, `lua/ge/extensions/core/vehicles.lua`, `lua/vehicle/ai.lua`, `lua/ge/extensions/core/trafficSignals.lua`) — ce ne sont pas des suppositions.

**Statut** : premier test en jeu réussi (respecte le code de la route, roule à la bonne vitesse). Trois points remontés par ce test ont été corrigés depuis (freinage tardif aux feux, hésitation en tournant à un carrefour, ajout des personnalités de conducteurs) — voir l'avertissement en tête de `core.lua` et la section 10 de `docs/ARCHITECTURE.md`. **Pas encore re-testés en jeu.**

### Tests automatisés (hors-jeu)

`idm.lua`, `roadGraph.lua`, `trafficLights.lua` et `driverProfile.lua` sont du Lua pur (aucune dépendance BeamNG) et testés unitairement avec un interpréteur Lua 5.4 standalone. `core.lua` a un test de fumée qui vérifie qu'il se charge sans erreur de syntaxe et que ses dépendances se résolvent.
```
lua tests/lua/test_idm.lua
lua tests/lua/test_roadGraph.lua
lua tests/lua/test_trafficLights.lua
lua tests/lua/test_driverProfile.lua
lua tests/lua/test_core_smoke.lua
```
Tous passent actuellement.

## Installer et tester — une seule action manuelle

`dist/beamai.zip` a été reconstruit avec les trois corrections. Je n'ai pas pu le déposer moi-même dans ton dossier de mods (Windows bloque l'écriture dans `Documents` depuis cet environnement), donc :

1. Remplace `dist/beamai.zip` dans `Documents\BeamNG.drive\0.38\mods\` (même nom, il suffit d'écraser l'ancien)
2. Lance BeamNG.drive, charge **West Coast, USA**, attends ~5 secondes
3. Observe le trafic, en particulier :
   - **Freinage aux feux** : est-ce plus progressif qu'avant, ou encore tardif ?
   - **Carrefours** : un véhicule qui tourne hésite-t-il/panique-t-il encore à cause d'un véhicule qui traverse ?
   - **Personnalités** : vois-tu des véhicules rouler visiblement plus vite/plus lentement que d'autres, ou un qui grille occasionnellement un feu ?

**Ce qu'il faut me dire** : toute erreur console (texte exact) · si les trois points ci-dessus sont améliorés · tout nouveau comportement bizarre.

Ce qui n'est **pas** dans ce correctif (évoqué mais pas traité) : l'esquive d'obstacle avec franchissement de ligne blanche — ça demande un contrôle latéral que le mod n'a pas encore (aujourd'hui, seul `ai.setSpeed` est piloté). C'est la prochaine grosse pièce (phase 3), pas un correctif rapide.

### Reconstruire le zip après une modification

```
python tools/extract_road_graph.py "<Steam>/content/levels/west_coast_usa.zip" -o mod/lua/ge/extensions/beamai/data/west_coast_usa.roadgraph.json
```
puis compresser le contenu de `mod/` (pas le dossier `mod` lui-même — le zip doit avoir `lua/` à sa racine) en `dist/beamai.zip`.
