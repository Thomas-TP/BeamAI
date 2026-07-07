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
- `avoidance.lua` — machine à états (idle → contournement → retour) qui gère la durée/l'hystérésis du contournement, plus un décalage latéral continu et progressif (`currentOffsetMetres`) utilisé en pilotage complet ; pure et testée
- `steeringController.lua` — **contrôleur de direction maison** (pure pursuit) : calcule l'angle de braquage à partir de la position/cap/vitesse du véhicule et d'un point de visée sur notre propre graphe routier
- `speedController.lua` — **contrôleur de vitesse maison** (PID) : convertit une vitesse cible en accélérateur/frein
- `core.lua` — orchestrateur : au chargement d'une carte pour laquelle un graphe est fourni, charge le graphe et enregistre automatiquement tous les véhicules (et re-scanne toutes les 3s) — aucune commande console requise pour la partie validée
- `data/west_coast_usa.roadgraph.json` — graphe pré-généré, embarqué dans le mod

Chaque appel à l'API du jeu a été vérifié directement dans le code source du jeu installé (`lua/ge/ge_utils.lua`, `lua/ge/extensions/core/vehicles.lua`, `lua/vehicle/ai.lua`, `lua/vehicle/input.lua`, `lua/common/inputFilters.lua`, `lua/ge/extensions/core/trafficSignals.lua`) — ce ne sont pas des suppositions.

**Changement de cap du projet** : ce mod ne s'appuie plus du tout sur le pilotage natif de BeamNG (`ai.setSpeed`, évitement natif). Il pilote directement le véhicule — direction, accélérateur, frein — via `input.event(...)`, le même canal bas niveau que `ai.lua` utilise lui-même en interne (`driveCar()`), avec `ai.setMode('disabled')` envoyé une fois pour que l'IA native cesse d'agir sur le véhicule. Le code source du jeu n'est plus utilisé que pour comprendre quels paramètres prendre en compte, pas comme moteur de décision.

**Statut** :
- ✅ **Validé en jeu** : suivi de véhicule (ancien système), respect des feux, bonne vitesse (premier playtest), puis contournement d'obstacle confirmé fonctionnel (avec l'ancien système appuyé sur l'évitement natif).
- 🔧 **Corrigé depuis, pas encore re-testé** : freinage tardif aux feux, hésitation en tournant à un carrefour, personnalités de conducteurs, performance (scan de segment "sticky") — voir Test 3.
- 🆕 **Pilotage complet maison (`setFullControlEnabled`) — jamais testé en jeu, le changement le plus risqué à ce jour.** Contrairement à tout ce qui précède, il n'y a plus aucun filet de sécurité natif une fois l'IA du jeu désactivée : si le calcul de direction est faux, rien ne rattrape le véhicule. Un premier essai de test n'a en fait rien activé du tout (voir l'encadré au début du Test 5) — encore à valider. Prévu justement pour être testé à part, à petite échelle — voir Test 5. L'évitement d'obstacle en pilotage complet est maintenant codé (décalage du point de visée du pure pursuit, plus de dépendance à l'évitement natif) mais pas encore testé en jeu non plus. Reste non traité : choix de direction à un vrai carrefour (vise le carrefour lui-même plutôt que de deviner une branche).

### Tests automatisés (hors-jeu)

`idm.lua`, `roadGraph.lua`, `trafficLights.lua`, `driverProfile.lua`, `mobil.lua`, `avoidance.lua`, `steeringController.lua` et `speedController.lua` sont du Lua pur (aucune dépendance BeamNG) et testés unitairement avec un interpréteur Lua 5.4 standalone — y compris une simulation en boucle fermée qui vérifie que le PID converge réellement vers la vitesse cible. `core.lua` a un test de fumée qui vérifie qu'il se charge sans erreur de syntaxe et que ses dépendances se résolvent.
```
lua tests/lua/test_idm.lua
lua tests/lua/test_roadGraph.lua
lua tests/lua/test_trafficLights.lua
lua tests/lua/test_driverProfile.lua
lua tests/lua/test_mobil.lua
lua tests/lua/test_avoidance.lua
lua tests/lua/test_steeringController.lua
lua tests/lua/test_speedController.lua
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

### Test 5 — pilotage complet maison (nouveau, à tester avec beaucoup de prudence)

**Ne teste pas ça en pleine circulation.** Sans l'IA native, un véhicule avec un mauvais calcul de direction pourrait sortir de la route ou percuter quelque chose — c'est exactement pour ça qu'il faut d'abord l'isoler.

**Piège découvert lors du premier essai — à ne pas refaire** : faire juste `extensions.reload("beamai_core")` puis `setFullControlEnabled(true)` **ne pilote rien du tout**. Le reload remet tout le module à zéro (`M.enabled=false`, `M.graph=nil`, aucun véhicule suivi) et `onClientStartMission` — le hook qui charge normalement le graphe et active tout automatiquement — ne se redéclenche **pas** juste parce que l'extension a été rechargée (il ne se déclenche qu'au vrai chargement d'un niveau). Résultat : `onUpdate` s'arrête à sa toute première ligne (`M.enabled` est faux), aucun véhicule n'a jamais reçu `ai.setMode('disabled')`, et ce qui roulait à l'écran était encore 100 % l'IA native du jeu. Il faut dérouler **toute** la séquence ci-dessous à chaque fois, après un reload.

1. Choisis **un seul véhicule IA**, sur une route **droite et vide** si possible (une autoroute dégagée, ou une rue sans autre circulation ni carrefour proche)
2. Note son ID (`local ids={};for i=0,be:getObjectCount()-1 do table.insert(ids,be:getObject(i):getID()) end;dump(ids)` puis identifie-le visuellement)
3. Repars d'un état propre, puis désactive le re-scan automatique **avant** d'activer quoi que ce soit — sinon, dans les 3 secondes qui suivent `setEnabled(true)`, `onUpdate` embarque automatiquement tous les autres véhicules de la carte, et s'il voit déjà `fullControlEnabled=true`, il coupe aussi leur IA native à eux (pas seulement celle du véhicule visé) :
```lua
extensions.reload("beamai_core")
extensions.beamai_core.setAutoScanEnabled(false)
extensions.beamai_core.setGraphPath("lua/ge/extensions/beamai/data/west_coast_usa.roadgraph.json")
extensions.beamai_core.registerVehicle(82723)
extensions.beamai_core.setFullControlEnabled(true)
extensions.beamai_core.setEnabled(true)
```
4. Observe le véhicule pendant plusieurs secondes, à basse vitesse si possible
5. Une fois le test terminé (concluant ou non) : `extensions.beamai_core.setEnabled(false)` pour tout arrêter proprement, puis `extensions.reload("beamai_core")` avant de repartir sur autre chose

**Dis-moi précisément** :
- Le véhicule reste-t-il sur la route, ou part-il dans le décor ? (si oui, arrête tout de suite : `extensions.beamai_core.setEnabled(false)`)
- Braque-t-il du bon côté pour suivre la route, ou part-il dans la direction opposée ? (si c'est inversé, un seul signe à changer dans `steeringController.lua`, `M.STEERING_SIGN`)
- La vitesse est-elle stable et fluide, ou oscille-t-elle (accélère/freine sans cesse) ?
- Toute erreur console (texte exact).

Une fois ce premier test concluant, l'étape suivante est de réactiver `setAvoidanceEnabled(true)` avec un deuxième véhicule (ou un obstacle statique) pour valider le nouvel évitement d'obstacle en pilotage complet (voir plus bas) — mais seulement après avoir confirmé que le pilotage de base (direction + vitesse) est fiable tout seul.

### Évitement d'obstacle en pilotage complet (nouveau, pas encore testé en jeu)

Depuis ce changement, l'évitement en pilotage complet **ne s'appuie plus du tout sur l'évitement natif** (impossible de toute façon, puisque `ai.lua` est désactivé) : quand un obstacle proche et quasi à l'arrêt est détecté (`mobil.shouldAttemptObstacleAvoidance`), le mod vérifie quel côté (gauche ou droite) est réellement dégagé des autres véhicules suivis (`roadGraph.isOffsetPathClear`) puis décale progressivement le point de visée du pure pursuit vers ce côté (`avoidance.currentOffsetMetres`, une transition en douceur plutôt qu'un saut brutal) le temps du dépassement, avant de le ramener au centre. Si aucun des deux côtés n'est dégagé, le véhicule ne tente rien ce tick-là et se contente de garder une distance de sécurité via IDM — il retentera au tick suivant. Activable via `extensions.beamai_core.setAvoidanceEnabled(true)` (déjà utilisé par le Test 4, mais avec un comportement différent selon que `fullControlEnabled` est actif ou non). Validé uniquement par tests unitaires à ce stade.

### Regénérer le graphe embarqué (rare, seulement si `tools/extract_road_graph.py` change)

```
python tools/extract_road_graph.py "<Steam>/content/levels/west_coast_usa.zip" -o mod/lua/ge/extensions/beamai/data/west_coast_usa.roadgraph.json
```
