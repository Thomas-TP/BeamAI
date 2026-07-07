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

**Zéro commande console requise** : au chargement d'une carte pour laquelle un graphe est fourni (`west_coast_usa` aujourd'hui), le mod charge automatiquement son graphe et bascule **tout le trafic** (chaque véhicule sauf le tien) sur le pilotage complet maison — pas juste la vitesse. Lance le jeu, charge la carte, c'est tout. Ce comportement par défaut (`M.autoFullControlOnStart`) peut être désactivé sans relancer le jeu si besoin (`extensions.beamai_core.setAutoFullControlOnStart(false)` puis recharger la carte) pour retomber sur l'ancien pilotage vitesse-seule, plus prudent mais moins abouti.

**Statut** :
- ✅ **Validé en jeu (ancien système, vitesse seule)** : suivi de véhicule, respect des feux, bonne vitesse, puis contournement d'obstacle confirmé fonctionnel (appuyé sur l'évitement natif, aujourd'hui remplacé — voir plus bas).
- 🔧 **Corrigé depuis (toujours sur l'ancien système), pas encore re-testé** : freinage tardif aux feux, hésitation en tournant à un carrefour, personnalités de conducteurs, performance (scan de segment "sticky") — voir Test 3.
- 🆕🔴 **Pilotage complet maison — maintenant ACTIVÉ PAR DÉFAUT sur les cartes avec graphe embarqué, jamais validé en jeu jusqu'ici.** Le changement le plus risqué à ce jour, et le seul qui tourne désormais sans qu'on ait pu l'observer en conditions réelles au préalable : il n'y a plus aucun filet de sécurité natif une fois l'IA du jeu désactivée — si le calcul de direction est faux, rien ne rattrape le véhicule, pour tout le trafic à la fois. Un premier essai de test manuel n'avait en fait rien activé du tout (voir l'encadré du Test 5) ; le vrai premier test grandeur nature reste à faire — voir Test 5. L'évitement d'obstacle en pilotage complet est codé (décalage du point de visée du pure pursuit, plus de dépendance à l'évitement natif) mais désactivé par défaut (`setAvoidanceEnabled`) en attendant que le pilotage de base soit confirmé fiable. Reste non traité : choix de direction à un vrai carrefour (vise le carrefour lui-même plutôt que de deviner une branche).

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

### Test 5 — pilotage complet maison (maintenant automatique, premier vrai test en conditions réelles)

**Rien à taper.** Lance BeamNG.drive, charge **West Coast, USA**, attends quelques secondes que le trafic apparaisse. Depuis ce changement, tout ce trafic (hors ton propre véhicule) est piloté directement par `steeringController.lua`/`speedController.lua`, plus du tout par `ai.lua`. C'est le tout premier test en conditions réelles de ce pilotage — jamais observé en jeu avant ce test, seulement en simulation hors-jeu.

**Regarde en priorité, sur les premières minutes** :
- Les véhicules restent-ils sur la route, ou certains partent-ils dans le décor ?
- Braquent-ils du bon côté dans les virages, ou repartent-ils dans la direction opposée ? (si c'est inversé pour tout le monde à la fois, c'est un seul signe à changer dans `steeringController.lua`, `M.STEERING_SIGN` — un symptôme facile à reconnaître : ça part systématiquement du mauvais côté, pas aléatoirement)
- La vitesse est-elle stable et fluide, ou ça oscille (accélère/freine sans cesse) ?
- Toute erreur console (texte exact), surtout répétée.

**Si ça part mal** (sortie de route, comportement erratique généralisé) : `extensions.beamai_core.setEnabled(false)` dans la console coupe immédiatement ce mod pour tout le monde (recharge la carte ensuite pour que les véhicules déjà partis en pilotage maison retrouvent une IA native propre). Pour repartir sur l'ancien pilotage (vitesse seule, plus prudent, déjà validé en jeu) sans toucher au code : `extensions.beamai_core.setAutoFullControlOnStart(false)` puis recharge la carte.

**Dis-moi** : ce que tu observes sur ces quatre points, et si possible depuis quelle distance/angle tu regardais (un véhicule vu de loin masque des petits écarts de trajectoire qu'on verrait de près).

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
