# BeamAI

Refonte complète de l'IA de circulation pour BeamNG.drive — une IA de trafic qui respecte le code de la route et conduit comme un humain, pas comme un script.

Plan complet et architecture : [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

## Outils

### `tools/extract_road_graph.py`

Extrait un graphe routier sémantique (segments + intersections + feux) directement depuis un fichier `.zip` de carte BeamNG.drive standard — aucune instance du jeu en cours d'exécution requise, aucun BeamNG.tech/BeamNGpy nécessaire pour cette étape. Capture aussi `flipDirection` (le champ natif de BeamNG qui inverse le sens de circulation d'un segment `oneWay`) depuis peu — nécessaire pour que le routage (`router.lua`) ne propose jamais un trajet à contre-sens ; environ la moitié des segments de `west_coast_usa` sont `oneWay` (souvent une seule chaussée d'une route à double sens plutôt qu'une vraie rue à sens unique), donc ce n'est pas un cas marginal.

```
python tools/extract_road_graph.py "<Steam>/steamapps/common/BeamNG.drive/content/levels/west_coast_usa.zip"
```

Produit un fichier `<carte>.roadgraph.json` (segments de route, intersections détectées, feux tricolores appariés). Voir section 4.2 de `docs/ARCHITECTURE.md` pour le schéma complet et les limites connues de cette première passe.

### `mod/lua/ge/extensions/beamai/`

Le mod lui-même (Game Engine Lua) :
- `idm.lua` — modèle de poursuite (contrôle longitudinal)
- `roadGraph.lua` — chargement + géométrie du graphe routier : anticipation des feux sur plusieurs segments (`findUpcomingTrafficLight`), anticipation des carrefours à priorité/stop (`findUpcomingPriorityJunction`), détection de trafic proche d'un carrefour (`isCrossTrafficNearJunction`), filtre anti-trafic-traversant (`isPlausibleLeader`), recherche de segment "sticky" pour la performance (`findNearestSegmentNear`)
- `trafficLights.lua` — lecture de l'état d'un feu ; **échoue en sécurité** (un état illisible est traité comme rouge, jamais comme vert)
- `driverProfile.lua` — personnalité par véhicule (vitesse, distance de suivi, non-respect occasionnel des feux)
- `mobil.lua` — décision de contournement (inspiré MOBIL) : détecte un obstacle proche et quasi à l'arrêt
- `avoidance.lua` — machine à états (idle → contournement → retour) qui gère la durée/l'hystérésis du contournement, plus un décalage latéral continu et progressif (`currentOffsetMetres`) utilisé en pilotage complet ; pure et testée
- `steeringController.lua` — **contrôleur de direction maison** (pure pursuit) : calcule l'angle de braquage à partir de la position/cap/vitesse du véhicule et d'un point de visée sur notre propre graphe routier
- `speedController.lua` — **contrôleur de vitesse maison** (PID) : convertit une vitesse cible en accélérateur/frein
- `router.lua` — **routage A\*** sur le graphe de segments : calcule un itinéraire entre un segment de départ et un segment de destination, en respectant les sens uniques (`oneWay`/`flipDirection`) ; branché sur `core.lua` (destination aléatoire par véhicule, suivie à travers les vrais carrefours), testé unitairement (15 scénarios), **pas encore observé en jeu** — voir Statut
- `core.lua` — orchestrateur : au chargement d'une carte pour laquelle un graphe est fourni, charge le graphe et enregistre automatiquement tous les véhicules (et re-scanne toutes les 3s) — aucune commande console requise pour la partie validée
- `data/west_coast_usa.roadgraph.json` — graphe pré-généré, embarqué dans le mod

Chaque appel à l'API du jeu a été vérifié directement dans le code source du jeu installé (`lua/ge/ge_utils.lua`, `lua/ge/extensions/core/vehicles.lua`, `lua/vehicle/ai.lua`, `lua/vehicle/input.lua`, `lua/common/inputFilters.lua`, `lua/ge/extensions/core/trafficSignals.lua`) — ce ne sont pas des suppositions.

**Changement de cap du projet** : ce mod ne s'appuie plus du tout sur le pilotage natif de BeamNG (`ai.setSpeed`, évitement natif). Il pilote directement le véhicule — direction, accélérateur, frein — via `input.event(...)`, le même canal bas niveau que `ai.lua` utilise lui-même en interne (`driveCar()`), avec `ai.setMode('disabled')` envoyé une fois pour que l'IA native cesse d'agir sur le véhicule. Le code source du jeu n'est plus utilisé que pour comprendre quels paramètres prendre en compte, pas comme moteur de décision.

**Zéro commande console requise** : au chargement d'une carte pour laquelle un graphe est fourni (`west_coast_usa` aujourd'hui), le mod charge automatiquement son graphe et bascule **tout le trafic** (chaque véhicule sauf le tien) sur le pilotage complet maison — pas juste la vitesse. Lance le jeu, charge la carte, c'est tout. Ce comportement par défaut (`M.autoFullControlOnStart`) peut être désactivé sans relancer le jeu si besoin (`extensions.beamai_core.setAutoFullControlOnStart(false)` puis recharger la carte) pour retomber sur l'ancien pilotage vitesse-seule, plus prudent mais moins abouti.

### Comment vérifier que c'est vraiment BeamAI qui pilote, pas l'IA native de BeamNG

Trois façons de le confirmer, de la plus rapide à la plus solide :

1. **État du mod, dans la console Lua (Game Engine)** :
```lua
dump(extensions.beamai_core.enabled)              -- doit être true
dump(extensions.beamai_core.fullControlEnabled)   -- doit être true (sinon : ancien pilotage vitesse-seule)
dump(extensions.beamai_core.routingEnabled)
dump(extensions.beamai_core.junctionPriorityEnabled)
```
2. **Un véhicule précis est-il vraiment sous contrôle complet ?** (nouveau, pensé pour répondre exactement à cette question) :
```lua
dump(extensions.beamai_core.getTrackedVehicleIds())        -- liste des véhicules suivis par ce mod
dump(extensions.beamai_core.isVehicleUnderFullControl(12345)) -- remplace par un des ids ci-dessus ; doit être true
```
`isVehicleUnderFullControl` renvoie `false` pour un véhicule non suivi, ou suivi mais encore sur l'ancien chemin `ai.setSpeed`. `true` veut dire que `ai.setMode('disabled')` a bien été envoyé à ce véhicule précis et que c'est nous qui lui injectons direction/accélérateur/frein.
3. **Preuve comportementale, la plus parlante** : observe un véhicule à un **carrefour sans feu** (un vrai stop). L'IA native de BeamNG ne suit pas les panneaux stop/priorité (confirmé par la doc officielle, voir `docs/ARCHITECTURE.md` section 2.1) — elle ne s'arrête donc **jamais** à ce genre de carrefour. Si tu vois un véhicule s'arrêter complètement à un carrefour sans feu, même quand rien n'arrive en face, c'est forcément BeamAI qui le pilote : c'est un comportement que l'IA native ne sait pas produire.

**Deux bugs réels trouvés grâce à cette vérification, tous les deux corrigés** :
- **Le mod pouvait rester silencieusement inactif** : `enabled`/`fullControlEnabled` étaient tous les deux à `false`, et le log ne contenait strictement aucune ligne `beamai_core` — `onClientStartMission` (le hook qui active tout au chargement d'une carte) ne s'était jamais déclenché cette session-là. Corrigé par un second point d'entrée, `M.onExtensionLoaded()` (un vrai hook du jeu, confirmé dans le code source d'une extension officielle), qui vérifie directement quelle carte est chargée dès que l'extension elle-même se charge, au lieu de dépendre uniquement d'un futur événement de chargement de niveau qui pouvait ne jamais arriver.
- **Chute de 120 à 25 FPS à l'activation manuelle** : `router.findRoute` (le calcul d'itinéraire A\*) balayait sa file d'attente en entier pour trouver le meilleur candidat à chaque itération — sur les ~1300 segments de la carte, une destination un peu lointaine faisait grossir cette file à plusieurs centaines d'entrées, rebalayées en entier à chaque tour. Remplacé par un vrai tas binaire (min-heap), qui ramène ce coût à O(log n) au lieu de O(n) par itération — testé avec un graphe synthétique de 40+ segments pour s'assurer que ça tient à l'échelle.

**Statut** :
- ✅ **Validé en jeu — pilotage complet maison (direction + vitesse)** : confirmé par un vrai test grandeur nature, tout le trafic piloté par `steeringController.lua`/`speedController.lua`, plus aucune décision de `ai.lua`. C'est désormais le comportement par défaut.
- ✅ **Validé en jeu — évitement d'obstacle en pilotage complet** : confirmé fonctionnel ("il esquive"). Un bug a ensuite été trouvé et corrigé : `isOffsetPathClear` incluait l'obstacle lui-même dans sa propre vérification de dégagement, ce qui faisait échouer la manœuvre (et donc freiner jusqu'à l'arrêt au lieu de contourner) dans la plupart des cas plutôt que de rater juste les cas vraiment bloqués — corrigé, pas encore re-testé en jeu depuis le correctif.
- ✅ **Validé en jeu (ancien système, vitesse seule, avant le pilotage complet)** : suivi de véhicule, respect des feux, bonne vitesse, contournement d'obstacle via l'évitement natif (aujourd'hui remplacé).
- 🔧 **Corrigé depuis (sur l'ancien système), jamais re-testé isolément** : freinage tardif aux feux, hésitation en tournant à un carrefour, performance (scan de segment "sticky") — plausiblement déjà couvert par le test grandeur nature du pilotage complet, sans confirmation dédiée.
- ✅ **Testé en jeu — routage A\* (`router.lua`)** : redémarrage complet confirmé sans régression visible ("tout fonctionne"). Le suivi d'itinéraire lui-même (un véhicule qui choisit vraiment une branche à un carrefour à plusieurs sorties) n'a pas encore été confirmé spécifiquement — beaucoup de carrefours sont de simples continuations où l'ancien et le nouveau comportement se ressemblent visuellement. Repli sans toucher au reste si besoin : `extensions.beamai_core.setRoutingEnabled(false)`.
- 🆕🔴 **Priorité aux carrefours réels (stop / cédez-le-passage / priorité à la route principale) — nouveau, jamais testé en jeu.** Avant ce changement, un carrefour non signalé (`type == "junction"`) n'avait strictement aucune règle de priorité : les véhicules fonçaient dessus quel que soit le trafic croisé. `tools/extract_road_graph.py` assigne maintenant une règle par défaut à chaque carrefour réel (priorité à la route de catégorie supérieure si elle existe clairement, sinon **stop à toutes les branches** — le défaut le plus sûr en l'absence de donnée fiable, et le plus courant aux USA). Le véhicule qui doit céder s'arrête complètement une première fois (pas juste un ralenti — un vrai arrêt, même si le carrefour est vide), puis ne repart que si aucun autre véhicule suivi n'est détecté proche du carrefour. Pas de négociation FIFO entre plusieurs véhicules arrivés en même temps pour l'instant (limite connue, pas un oubli). Repli dédié, indépendant du routage : `extensions.beamai_core.setJunctionPriorityEnabled(false)`.

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

### Test 5 — pilotage complet maison (✅ confirmé en jeu)

**Rien à taper.** Lance BeamNG.drive, charge **West Coast, USA**, attends quelques secondes que le trafic apparaisse. Tout ce trafic (hors ton propre véhicule) est piloté directement par `steeringController.lua`/`speedController.lua`, plus du tout par `ai.lua`. **Confirmé fonctionnel** lors du premier test grandeur nature (avec évitement d'obstacle observé en prime). Si tu revois un problème après une mise à jour :
- Les véhicules restent-ils sur la route, ou certains partent-ils dans le décor ?
- Braquent-ils du bon côté dans les virages ? (si c'est inversé pour tout le monde à la fois, un seul signe à changer dans `steeringController.lua`, `M.STEERING_SIGN`)
- La vitesse est-elle stable et fluide, ou ça oscille ?

**Si ça part mal** : `extensions.beamai_core.setEnabled(false)` coupe immédiatement ce mod pour tout le monde (recharge la carte ensuite). Pour repartir sur l'ancien pilotage vitesse-seule sans toucher au code : `extensions.beamai_core.setAutoFullControlOnStart(false)` puis recharge la carte.

### Test 6 — routage et virages aux carrefours (nouveau, jamais testé en jeu)

**Rien à taper non plus.** Depuis ce changement, chaque véhicule en pilotage complet reçoit une destination aléatoire quelque part sur la carte et suit vraiment l'itinéraire calculé — y compris tourner à un vrai carrefour, ce qu'aucune version précédente ne faisait (elles visaient juste le carrefour lui-même et fonçaient dessus). C'est le changement le plus neuf du projet.

**Regarde en priorité** :
- Un véhicule qui approche un carrefour à plusieurs branches : tourne-t-il proprement dans une des branches, ou hésite-t-il / vise-t-il le milieu du carrefour sans se décider ?
- Le virage lui-même est-il fluide (le pure pursuit suit un point de visée qui se décale progressivement vers la nouvelle direction) ou brusque/saccadé ?
- Un véhicule finit-il par se retrouver bloqué, immobile, ou tourner en rond de façon absurde (signe que le routage ou le suivi d'itinéraire a un bug) ?
- Une micro-saccade générale juste après le chargement de la carte (le calcul d'itinéraire est plafonné à 2 par tick, donc étalé sur plusieurs secondes pour tous les véhicules — un ralentissement bref est possible, un vrai freeze ne devrait pas arriver).

**Si ça part mal** : `extensions.beamai_core.setRoutingEnabled(false)` désactive uniquement le routage sans toucher au reste (les véhicules continuent tout droit/s'arrêtent aux carrefours comme avant ce changement, mais gardent leur pilotage direction/vitesse).

**Dis-moi** : ce que tu observes à un carrefour en particulier (idéalement un carrefour à 3-4 branches, pas juste une route qui continue), et toute erreur console.

### Test 7 — priorité aux carrefours réels (nouveau, jamais testé en jeu)

**Toujours rien à taper.** Un carrefour non signalé (pas de feu) a maintenant une vraie règle de priorité : soit une route a clairement priorité sur l'autre (catégorie de route supérieure), soit — le cas le plus fréquent — **stop à toutes les branches**. Avant ce changement, ces carrefours n'avaient aucune règle et le trafic les traversait sans ralentir.

**Regarde en priorité, à un carrefour sans feu** :
- Un véhicule qui approche s'arrête-t-il complètement (pas juste ralentit) avant de repartir ?
- S'arrête-t-il même quand le carrefour est visiblement vide ? (c'est voulu — un vrai stop, pas juste un cédez-le-passage)
- Repart-il une fois arrêté, ou reste-t-il bloqué indéfiniment alors que rien n'approche ?
- Deux véhicules qui arrivent à peu près en même temps sur des branches différentes : se bloquent-ils mutuellement, ou l'un finit-il par repartir ? (pas de vraie négociation d'ordre de passage pour l'instant — limite connue, voir Statut)

**Si ça part mal** : `extensions.beamai_core.setJunctionPriorityEnabled(false)` désactive uniquement cette règle sans toucher au routage ni au reste.

**Dis-moi** : ce que tu observes à un carrefour à stop en particulier, et toute erreur console.

### Débogage isolé (un seul véhicule, si le Test 5 grandeur nature part mal)

Si le test ci-dessus montre un problème et qu'il faut l'isoler sur un seul véhicule pour comprendre (ex. confirmer le sens de `STEERING_SIGN` calmement), repars d'un état propre et pilote la mise en route toi-même plutôt que de laisser l'automatique embarquer tout le monde :

```lua
extensions.reload("beamai_core")
extensions.beamai_core.setAutoFullControlOnStart(false)  -- empêche l'automatique de reprendre la main
extensions.beamai_core.setAutoScanEnabled(false)          -- empêche le re-scan (3s) d'embarquer tous les autres véhicules
extensions.beamai_core.setGraphPath("lua/ge/extensions/beamai/data/west_coast_usa.roadgraph.json")
extensions.beamai_core.registerVehicle(82723)             -- remplace par l'ID du véhicule isolé, choisi sur une route droite et vide
extensions.beamai_core.setFullControlEnabled(true)
extensions.beamai_core.setEnabled(true)
```

**Piège déjà rencontré, à ne pas refaire** : faire juste `extensions.reload("beamai_core")` puis `setFullControlEnabled(true)`, sans le reste, **ne pilote rien du tout**. `extensions.reload` remet le module à zéro (`M.enabled=false`, `M.graph=nil`) mais ne redéclenche pas `onClientStartMission` (qui ne se déclenche qu'au vrai chargement d'un niveau) — `onUpdate` s'arrête alors à sa toute première ligne et rien n'est jamais envoyé au véhicule. C'est ce qui s'est produit lors du tout premier essai : ce qui roulait à l'écran était encore 100 % l'IA native.

Une fois le pilotage de base confirmé fiable (à l'isolé ou en grandeur nature), l'étape suivante est `extensions.beamai_core.setAvoidanceEnabled(true)` pour valider l'évitement d'obstacle en pilotage complet (voir plus bas).

### Évitement d'obstacle en pilotage complet (nouveau, pas encore testé en jeu)

Depuis ce changement, l'évitement en pilotage complet **ne s'appuie plus du tout sur l'évitement natif** (impossible de toute façon, puisque `ai.lua` est désactivé) : quand un obstacle proche et quasi à l'arrêt est détecté (`mobil.shouldAttemptObstacleAvoidance`), le mod vérifie quel côté (gauche ou droite) est réellement dégagé des autres véhicules suivis (`roadGraph.isOffsetPathClear`) puis décale progressivement le point de visée du pure pursuit vers ce côté (`avoidance.currentOffsetMetres`, une transition en douceur plutôt qu'un saut brutal) le temps du dépassement, avant de le ramener au centre. Si aucun des deux côtés n'est dégagé, le véhicule ne tente rien ce tick-là et se contente de garder une distance de sécurité via IDM — il retentera au tick suivant. Activable via `extensions.beamai_core.setAvoidanceEnabled(true)` (déjà utilisé par le Test 4, mais avec un comportement différent selon que `fullControlEnabled` est actif ou non). Validé uniquement par tests unitaires à ce stade.

### Regénérer le graphe embarqué (rare, seulement si `tools/extract_road_graph.py` change)

```
python tools/extract_road_graph.py "<Steam>/content/levels/west_coast_usa.zip" -o mod/lua/ge/extensions/beamai/data/west_coast_usa.roadgraph.json
```
