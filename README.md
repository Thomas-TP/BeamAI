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

**Deuxième changement de cap, après mesure en jeu** : ce mod a d'abord tenté de remplacer entièrement le pilotage natif (direction + vitesse pilotées par nous via `input.event(...)`, `ai.lua` désactivé). Une comparaison contrôlée en jeu (6 véhicules natifs = 120 FPS, 6 véhicules en pilotage complet = 30 FPS — même nombre de véhicules, donc même coût physique des deux côtés) a montré que ce coût est réel, soutenu, et ne dépend pas de l'échelle : un budget explicite a été fixé (**pas plus de ~5 FPS perdus** par rapport au trafic natif), que le pilotage complet ne peut pas tenir. **Le pilotage complet reste dans le code, désactivé par défaut** (`extensions.beamai_core.setFullControlEnabled(true)` pour le réactiver manuellement) — c'est une vraie ambition à long terme, pas un échec supprimé, mais ce n'est plus le chemin par défaut.

**Nouveau par défaut : `ai.lua` natif pilote, ce mod ne fait que corriger ce qu'on peut confirmer être faux.** Coût quasi nul puisque le pilotage/suivi de voie tourne de toute façon (piloté par le jeu ou par nous, la physique et le calcul de trajectoire natifs s'exécutent dans tous les cas) :
- **Limitation de vitesse par type de route** (`ai.setSpeed`/`ai.setSpeedMode('limit')`, le système déjà validé en jeu dès la phase 1) : 130 km/h autoroute, 80 sur route, 50 ou 30 en ville — cohérent avec le code de la route français.
- **Sécurité aux stops** (voir plus bas) : corrige un vrai trou trouvé en lisant `lua/vehicle/ai.lua` directement.
- **Sécurité au rabattement/changement de voie près du joueur** (voir plus bas) : atténue un vrai trou trouvé de la même façon — une atténuation, pas une correction parfaite (voir les limites listées).

Zéro commande console requise pour ce chemin par défaut : lance le jeu, charge la carte, c'est tout.

### Comment vérifier ce que fait BeamAI (mise à jour : `ai.lua` natif pilote par défaut désormais)

**Correction importante** : une note précédente ici affirmait, en se basant sur la doc officielle, que l'IA native de BeamNG ne suit pas du tout les panneaux stop/priorité. **Faux, vérifié directement dans `lua/vehicle/ai.lua`** (voir `docs/ARCHITECTURE.md` section 2.1 pour les numéros de ligne exacts) : elle s'arrête bel et bien à un vrai panneau stop placé sur la carte. Le vrai trou, confirmé dans le code : elle vérifie s'il y a du trafic qui arrive avant de repartir **seulement** pour les carrefours non signalés qu'elle détecte elle-même géométriquement (angle de virage), **jamais** pour un vrai panneau stop placé par le niveau — celui-là attend juste un délai fixe puis repart, qu'il y ait quelqu'un ou non. C'est exactement notre correctif ci-dessous.

Pour vérifier l'état du mod dans la console Lua (Game Engine) :
```lua
dump(extensions.beamai_core.enabled)               -- doit être true
dump(extensions.beamai_core.fullControlEnabled)    -- doit être false par défaut maintenant (pilotage natif + corrections)
dump(extensions.beamai_core.junctionPriorityEnabled) -- correctif stop/priorité, actif par défaut
```
```lua
dump(extensions.beamai_core.getTrackedVehicleIds())
dump(extensions.beamai_core.isVehicleUnderFullControl(12345)) -- doit être false par défaut désormais
```

**Deux bugs réels trouvés grâce à cette vérification, tous les deux corrigés** :
- **Le mod pouvait rester silencieusement inactif** : `enabled`/`fullControlEnabled` étaient tous les deux à `false`, et le log ne contenait strictement aucune ligne `beamai_core` — `onClientStartMission` (le hook qui active tout au chargement d'une carte) ne s'était jamais déclenché cette session-là. Corrigé par un second point d'entrée, `M.onExtensionLoaded()` (un vrai hook du jeu, confirmé dans le code source d'une extension officielle), qui vérifie directement quelle carte est chargée dès que l'extension elle-même se charge, au lieu de dépendre uniquement d'un futur événement de chargement de niveau qui pouvait ne jamais arriver.
- **Chute de 120 à 25 FPS à l'activation manuelle** : `router.findRoute` (le calcul d'itinéraire A\*) balayait sa file d'attente en entier pour trouver le meilleur candidat à chaque itération — sur les ~1300 segments de la carte, une destination un peu lointaine faisait grossir cette file à plusieurs centaines d'entrées, rebalayées en entier à chaque tour. Remplacé par un vrai tas binaire (min-heap), qui ramène ce coût à O(log n) au lieu de O(n) par itération — testé avec un graphe synthétique de 40+ segments pour s'assurer que ça tient à l'échelle.
- **Deuxième chute, cette fois soutenue (pas juste au démarrage) : 120 → 30 FPS.** La recherche de feu/carrefour à venir (`findUpcomingTrafficLight`, puis `findUpcomingPriorityJunction` ajouté juste après) rebalayait tous les ~646 carrefours candidats de la carte à chaque étape de sa progression le long de la route — et ce, **deux fois par véhicule à chaque tick** une fois la priorité aux carrefours ajoutée (une fois pour les feux, une fois pour les stops), sans compter un balayage de tous les ~1300 segments à chaque saut de continuation. Les deux fonctions ont été déplacées dans `router.lua` et fusionnées en une seule traversée, utilisant les tables déjà construites une fois pour toutes au chargement du graphe (`buildIndex`) au lieu de rebalayer quoi que ce soit — coût ramené de O(nb carrefours) à O(1) par étape, et un seul passage au lieu de deux. Corrige au passage un bug latent : ces fonctions supposaient toujours un déplacement "vers l'avant" du segment, ignorant qu'un véhicule peut légalement rouler dans les deux sens sur une route à double sens — testé explicitement dans les deux sens maintenant.
- **Comparaison contrôlée faite par l'utilisateur, sans appel possible** : 6 véhicules de trafic natif BeamNG = 120 FPS ; 6 véhicules pilotés par BeamAI = 30 FPS. Même nombre de véhicules, donc même coût de simulation physique "soft-body" des deux côtés — l'écart est donc à 100 % dans notre code Lua, pas dans le moteur. Le coût du balayage de carrefours ci-dessus (`findUpcomingTrafficLight`/`findUpcomingPriorityJunction`) ne dépend PAS du nombre d'autres véhicules suivis — c'est un coût fixe par véhicule (~646 carrefours + ~1300 segments rebalayés, deux fois, à chaque tick), donc à lui seul plausiblement suffisant pour expliquer une grosse partie de l'écart même avec seulement 6 véhicules. Malgré ce correctif, le pilotage complet reste fondamentalement plus coûteux que le pilotage natif (pure pursuit + PID + suivi d'itinéraire calculés par nous, chaque tick, en plus de ce que le jeu calcule déjà) — **décision finale : le pilotage complet passe en désactivé par défaut**, `ai.lua` natif reprend le volant, ce mod se contente de corriger des défauts confirmés (voir plus haut et plus bas).

**Statut** :
- 🆕 **Priorité à la sécurité aux stops, corrigeant un vrai trou confirmé dans `ai.lua`** — pas encore re-testé en jeu depuis le retour au pilotage natif. `tools/extract_road_graph.py` assigne une règle de priorité à chaque carrefour réel (hiérarchie de route si elle existe clairement, sinon **stop à toutes les branches**). `core.findJunctionPriorityConstraint` force un vrai arrêt complet (même carrefour vide) au premier passage, puis ne cède que si du trafic réel est détecté à proximité — appliqué via `ai.setSpeed()`, donc actif que le véhicule soit en pilotage natif ou complet. Corrige précisément le trou identifié dans `ai.lua` (voir ci-dessus et `docs/ARCHITECTURE.md` section 2.1) : un vrai panneau stop placé sur la carte n'y vérifie jamais le trafic réel avant de repartir. Repli dédié : `extensions.beamai_core.setJunctionPriorityEnabled(false)`.
- 🆕 **Atténuation du rabattement/changement de voie près du joueur (`playerMergeSpeedCap`)** — mitigation, pas une correction parfaite (voir Limites connues). Ralentit temporairement un véhicule suivi qui dérive latéralement (changement de voie en cours) quand le joueur le suit de près, pour élargir l'écart laissé — sans jamais toucher au code natif de décision de changement de voie (`ego.ghostL/R`, interne à `ai.lua`, non exposé). Pas encore testé en jeu.
- 🔧 **Limites de vitesse par type de route** : 130 km/h autoroute / 80 route / 50-30 ville (défauts de `tools/extract_road_graph.py`, section `DEFAULT_SPEED_LIMIT_KMH`) — système déjà validé en jeu dans son principe (phase 1), valeurs mises à jour suite à ce changement de cap.
- 🔧 **Pilotage complet maison (direction + vitesse, `steeringController.lua`/`speedController.lua`/`router.lua`)** : fonctionnel et validé en jeu (y compris l'évitement d'obstacle et le routage/virages), mais **désactivé par défaut** depuis la découverte de son coût FPS réel. Reste appelable manuellement (`extensions.beamai_core.setFullControlEnabled(true)`) pour continuer à le développer/tester à part, sans l'imposer à tout le trafic.
- ✅ **Évitement d'obstacle réactivé pour le pilotage natif (`awarenessForceCoef`)** — la technique déjà confirmée par un test en jeu précédent ("oui il esquive"), réactivée par défaut maintenant que c'est le chemin par défaut. Une tentative de la remplacer par `ai.driveUsingPath({routeOffset=...})` (trouvée dans un vrai mod communautaire) a été écrite puis entièrement retirée avant tout commit : vérification directe dans notre `ai.lua` installé a montré que ce paramètre n'existe pas du tout dans notre version du jeu (0.38.6) et n'aurait rien fait — voir `docs/ARCHITECTURE.md` section 10, point 20, pour le détail complet.
- ✅ **Validé en jeu (ancien système vitesse-seule, base du chemin par défaut actuel)** : suivi de véhicule, respect des feux, bonne vitesse.

**Recherche approfondie sur les problèmes connus de l'IA native** (demandée explicitement, voir `docs/ARCHITECTURE.md` section 10 point 20 pour le détail complet et les sources) :
- **Confirmés et déjà corrigés/atténués ci-dessus** : le trou stop/priorité, le point aveugle de changement de voie.
- **Confirmés, pas encore corrigés** : le freinage d'urgence natif a un bug **admis par les développeurs de BeamNG eux-mêmes** dans leurs propres commentaires de code ("it is not working due to false flag") ; aucune logique de dépassement d'un véhicule plus lent mais en mouvement n'existe nativement (confirmé : zéro fonction "overtake" dans tout `ai.lua`) — un vrai trou, pas une supposition, mais sans solution bon marché confirmée pour l'instant (le `routeOffset` qui aurait pu servir n'existe pas, voir plus haut).
- **Déjà géré nativement, pas la peine de reconstruire** : la cession de passage à un véhicule de police (gyrophare détecté, ~100m, alignement de direction vérifié) existe déjà dans `ai.lua`.
- **Honnêteté sur le reste** : accidents, dépêche policière, météo/adhérence, stationnement, ronds-points, dépassement réel restent des chantiers non commencés — "corriger tous les problèmes" en une session n'est pas réaliste au niveau de rigueur (tout confirmé, rien inventé) que ce projet s'impose.

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
