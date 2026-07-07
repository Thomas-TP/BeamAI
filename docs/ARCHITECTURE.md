# BeamAI — Refonte complète de l'IA de circulation pour BeamNG.drive

Document de conception. Rédigé après recherche approfondie sur (1) le fonctionnement actuel et le modding de BeamNG.drive, (2) les systèmes de trafic de simulateurs comparables (ETS2/ATS, Assetto Corsa, City Car Driving, GTA V, CARLA, SUMO) et les formats de cartes standards (OpenDRIVE, OpenStreetMap), (3) les architectures de conduite autonome réelles (Tesla FSD, Waymo, Cruise, Mobileye RSS, NVIDIA SFF, Baidu Apollo) et la recherche académique (IDM, MOBIL, Social Force Model, Behavior Trees, POMDP, RL/IL).

Statut : recherche terminée, conception initiale. Aucune ligne de code écrite à ce stade.

---

## 1. Vision

BeamNG.drive a un atout unique qu'aucun concurrent ne possède : une physique soft-body complète, appliquée identiquement au joueur et à l'IA. Le problème n'est donc pas la simulation du véhicule — c'est la **couche de décision** au-dessus. L'IA actuelle ne "sait" quasiment rien du monde qui l'entoure au sens des règles : elle suit un graphe de navigation et évite des obstacles au raycast, sans modèle explicite de priorité, de courtoisie, ou d'incertitude sur les intentions des autres.

L'objectif de BeamAI est de construire cette couche manquante : un système de décision multi-véhicules qui **comprend** le code de la route (pas juste des feux qui changent de couleur), **anticipe** les autres usagers, et **se trompe parfois comme un humain** plutôt que d'être soit parfait soit stupide.

Principes directeurs retenus après recherche :

1. **Réutiliser la vérité terrain, ne pas réinventer la perception.** BeamNG fournit déjà les positions/vitesses exactes de tous les objets via Lua. Contrairement à une vraie IA embarquée, on n'a pas besoin de réseaux de perception (YOLO, occupancy networks) — l'effort doit porter sur la **prédiction, la décision et le contrôle**, pas sur la vision. On peut en revanche *dégrader volontairement* cette vérité terrain pour simuler un temps de réaction et une attention humaine imparfaite.
2. **Hybride règles formelles + apprentissage, pas du tout-ML.** Le consensus qui ressort de la recherche (Mobileye RSS, NVIDIA SFF, Apollo Guardian) est qu'un système de sécurité critique a besoin d'une couche **vérifiable et déboguable**. On construit donc un socle de modèles formels (IDM, MOBIL, règles de priorité) et on réserve l'apprentissage (imitation/RL) au calibrage fin et aux cas rares, en phase ultérieure.
3. **Architecture en couches indépendantes**, inspirée d'Apollo et de CARLA Traffic Manager : perception → prédiction → décision → planification → contrôle → **couche de sécurité indépendante qui peut tout annuler**.
4. **Un moteur de règles séparé des données de carte.** BeamNG ne stocke pas nativement les priorités d'intersection ni certaines limitations de vitesse par segment. On construit un **graphe routier sémantique** en une passe hors-ligne par carte, qui devient la source de vérité pour l'IA — et qui permet aussi la **localisation par pays** (conduite à gauche, priorité à droite implicite, stop obligatoire vs cédez-le-passage, etc.).
5. **Honnêteté sur les limites.** Piétons explicitement hors scope (choix produit), moteur fermé (boîte noire physique/rendu), synchronisation multijoueur non triviale. Ces points sont traités en section 9.
6. **Un trafic vivant, pas un flux figé.** Les véhicules garés et les véhicules en circulation doivent pouvoir s'échanger continuellement (section 4.3bis) — remplace le spawn/despawn hors champ par un cycle de vie visible, sans téléportation.

---

## 2. Synthèse des recherches

### 2.1 BeamNG.drive — état actuel et modding

- **IA véhicule** : 8 modes (`Random`, `Chase`, `Flee`, `Follow`, `Manual`, `Stopping`, `Span`, `Traffic`), pilotables via l'app in-game ou l'API Lua/BeamNGpy (`ai.setMode`, `ai.setAggression`, `ai.setSpeed`, `ai.setTarget`, `ai.driveInLane`, etc.). Un développeur BeamNG (Nadeox1) confirme que l'IA utilise la **même physique que le joueur**, sans triche de trajectoire — contrairement aux IA de jeux de course classiques.
- **Mode Traffic** : respecte les feux tricolores (système natif), mais **ne suit pas les panneaux stop/priorité** créés via le Traffic Manager — confirmé explicitement par la documentation officielle. C'est le trou principal que BeamAI doit combler.
- **Feux tricolores** : gérés par `lua/ge/extensions/core/trafficSignals.lua`, configuration par carte (`signals.json`), **état local au client** (pas d'autorité serveur en multijoueur → risque de désync, confirmé par un ticket BeamMP).
- **Graphe routier** : le Decal Road Editor expose `drivability`, `lanesLeft`/`lanesRight`, `oneWay`/`flipDirection`, `gatedRoad`. **Aucune métadonnée de priorité ou de limitation de vitesse par segment** n'a été trouvée documentée à ce niveau — à construire nous-mêmes.
- **Capteurs** : le "Roads sensor" (BeamNG.tech) donne courbure, cap, largeur, polylignes et splines au format **ASAM OpenDRIVE**. BeamNGpy expose aussi caméra, LiDAR, radar classique, **Ideal RADAR** (position/vitesse relative vérité-terrain), IMU, GPS, capteur de dégâts.
- **Piétons** : absents nativement. Seuls des mods communautaires expérimentaux existent (MOSEZ BeamPedestrians, etc.) — un vrai chantier à part entière.
- **Mods existants pertinents** : *Dynamic AI Traffic Mod*, *Traffic Reborn*, *Realistic AI Traffic Behaviors*, et surtout **Advanced Traffic AI** (GitHub, 100 % Lua) qui remplace déjà l'IA de trafic par défaut avec des profils de conducteurs, des feux/stops virtuels aux intersections, la priorité à droite, et une gestion post-accident — la preuve que l'architecture envisagée ici est réalisable en Lua pur, sans toucher au moteur.
- **Deux VM Lua** : Game Engine Lua (orchestration globale : trafic, feux, carrière) et Vehicle Lua (une VM isolée par véhicule, communication asynchrone entre les deux).
- **Import de cartes réelles** : pas d'outil officiel "OSM2BeamNG", mais l'outil communautaire **MapNG** convertit des données OpenStreetMap + relief réel en niveau BeamNG (terrain, routes, bâtiments).

### 2.2 Simulateurs comparables

- **ETS2/ATS (SCS)** : intersections en "prefabs" avec sémaphores liés explicitement aux chemins IA (sans référence, l'IA ignore le feu) — validé le principe que la **liaison explicite feu↔chemin** est nécessaire, pas une simple détection géométrique.
- **Assetto Corsa** (2REAL/csp-traffic-tool) : sépare la donnée statique (splines de voie) de la logique de trafic (moteur externe) — argument pour découpler notre graphe sémantique de la logique de décision.
- **City Car Driving** : l'IA peut **délibérément commettre des fautes calibrées** pour un trafic crédible — argument clé pour ne pas viser une IA "parfaite".
- **GTA V** : format `.ynd` (nœuds avec voies, limite de vitesse, taux de spawn) — modèle compact de graphe de navigation à réutiliser comme inspiration de schéma.
- **CARLA Traffic Manager** — la référence la plus riche : pipeline en étages (localisation → collision → feux/priorités **FIFO** aux jonctions non signalées → planificateur de mouvement PID → gestion des feux véhicule), profils **Cautious/Normal/Aggressive**, **mode hybride physique** (désactiver la physique complète hors d'un rayon autour du joueur) essentiel pour la performance à grande échelle, `WalkerAIController` pour les piétons (avec sa limite connue : nav-mesh séparé de la route).
- **SUMO** : modèle de poursuite **Krauss** (simple, sans collision, basé distance de freinage sûre) et **IDM**, changement de voie **LC2013**/**SL2015** (sous-voies progressives), feux **actuated** (extension de phase selon détection de flux) — tout un jeu de modèles microscopiques directement réutilisables.
- **OpenDRIVE** : structure ligne-de-référence + voies + jonctions typées (communes/directes/virtuelles/croisement) — modèle de référence pour notre graphe sémantique.
- **OpenStreetMap** : tags exploitables — `highway=*` (hiérarchie ⇒ priorité implicite), `maxspeed`, `oneway`, `junction=roundabout`, `traffic_signals`, `highway=stop` (arrêt obligatoire même sans trafic, à distinguer de `give_way`), `priority_road`, `lanes`/`lanes:bus`/`cycleway` — directement réutilisables pour dériver des priorités automatiquement si on importe une vraie carte.

### 2.3 IA de conduite autonome réelle et recherche académique

- **Tesla FSD** : réseau end-to-end (photons → commandes), tronc partagé "HydraNet" avec têtes spécialisées, "occupancy networks" (volume 3D d'occupation générique), "vector space" (représentation unifiée voies/objets), "shadow mode" (test silencieux d'un nouveau modèle en production). Approche tout-caméra.
- **Waymo Driver / ChauffeurNet** : pipeline modulaire perception→prédiction→planification→contrôle. ChauffeurNet montre que le pur clonage comportemental échoue sur les cas rares — il faut **synthétiser des perturbations** (quasi-collisions, sorties de voie) et ajouter des pertes de pénalité. MultiPath++ pour la prédiction multimodale des autres agents.
- **Cruise** : architecture modulaire classique + **supervision à distance** pour les cas ambigus (chantier, obstacle atypique) — un concept transposable à un mode "intervention développeur" en debug.
- **Mobileye — RSS (Responsibility-Sensitive Safety)** : modèle **formel et mathématique**, 5 règles (distance longitudinale sûre, distance latérale sûre, priorité reçue et non prise, prudence en visibilité limitée, éviter toute collision évitable). Objectif : ne jamais être **responsable** d'une collision. Implémentation open source `ad-rss-lib` déjà intégrée à Apollo et CARLA.
- **NVIDIA Safety Force Field** : couche de supervision indépendante calculant, pour chaque objet, un "Claimed Set" (volume spatio-temporel qu'il occuperait en freinage/braquage d'urgence) ; un chevauchement signale un risque, et SFF calcule la correction **minimale** par rapport à l'intention du planificateur.
- **Baidu Apollo (open source, la référence architecturale la plus directement réutilisable)** : middleware **Cyber RT** (pub-sub, ordonnancement en coroutines), modules Perception/Prediction/Localization/Routing/Planning/Control/HD-Map/**Guardian** (filet de sécurité indépendant capable d'un arrêt sûr). L'**EM Planner** découple optimisation du chemin et de la vitesse dans un repère de Frenet construit sur la route de référence.
- **Modèles académiques clés** :
  - **IDM** (Treiber et al., 2000) : contrôle longitudinal, formule fermée, paramètres intuitifs (vitesse désirée, temps intervéhiculaire, accélération/freinage max, distance à l'arrêt).
  - **MOBIL** (Kesting et al., 2007) : décision de changement de voie par critère de sécurité + critère d'incitation pondéré par un **facteur de politesse**.
  - **Social Force Model** (Helbing & Molnár, 1995) : base pour l'IA piétons (forces d'attraction/répulsion).
  - **Behavior Trees** préférés aux FSM rigides pour la décision haut niveau (modularité, réactivité).
  - **POMDP/MDP** pour la négociation aux intersections sous incertitude (occlusions, intentions inconnues).
  - **RL + Imitation Learning hybride** : le clonage comportemental pur souffre des cas rares ; combiner avec du renforcement réduit les événements dangereux dans plusieurs études récentes. Entraînement/calibration sur des jeux de données réels (Waymo Open Dataset, nuScenes, highD, INTERACTION).

---

## 3. Ce que le moteur permet vraiment (contraintes de départ)

| Possible en Lua pur (validé par des mods existants) | Limité / à construire de zéro | Boîte noire (non modifiable) |
|---|---|---|
| Contrôle complet d'un véhicule IA (vitesse, cible, trajectoire, agressivité) | Priorités d'intersection (stop, cédez le passage, priorité à droite) — non suivies nativement | Solveur physique soft-body |
| Lecture des feux tricolores et de leur état | Limitation de vitesse par segment fiable | Rendu, construction du graphe de navigation interne bas niveau |
| Lecture du graphe de route (voies, sens unique, praticabilité) | Cyclistes/animaux (aucun comportement IA natif, mais traitables comme véhicules légers sur le même graphe) | — |
| Détection d'autres véhicules par raycast/API | Synchronisation multijoueur de l'état trafic (feux locaux au client) | — |
| Spawn/despawn, personnalités, densité | Perf à grande échelle avec calcul complet par véhicule (nombre max non documenté officiellement) | — |

**Décision de périmètre** : les piétons sont explicitement hors scope (choix produit, pas une limite technique constatée) — cela simplifie fortement la section 7.G et supprime le chantier le plus coûteux identifié pendant la recherche.

Conséquence directe sur l'architecture : **tout le raisonnement "règles de la route" doit être construit par BeamAI**, indépendamment du moteur, à partir d'un graphe enrichi que nous créons nous-mêmes.

---

## 4. Architecture proposée

### 4.1 Vue d'ensemble en couches

```
                    ══════════ HORS-LIGNE (une fois par carte) ══════════
   [Carte BeamNG / import OSM]
            │
            ▼
   ① Extracteur de graphe routier  ──▶  ② Graphe routier sémantique (JSON)
   (Python stdlib, lit DecalRoad et           (voies, jonctions, priorités,
    signals.json directement dans le .zip)     vitesses, ruleset pays)
                                                      │
                    ══════════ TEMPS RÉEL (par véhicule IA, Lua) ══════════
                                                      ▼
   ③ Perception & conscience situationnelle  (positions/vitesses vérité-terrain
      + dégradation humaine : temps de réaction, angle mort, distraction)
                                                      │
                                                      ▼
   ④ Prédiction  (trajectoire probable des autres agents : clignotant,
      vitesse constante, historique court terme, occlusions aux intersections)
                                                      │
                                                      ▼
   ⑤ Décision — Behavior Tree  (Suivre voie / Approche intersection / Céder /
      Tourner / Dépasser / Fusionner / Se garer / Demi-tour / Urgence / ...)
      ← interroge le ruleset du graphe sémantique (pays, type d'intersection)
                                                      │
                                                      ▼
   ⑥ Planification  (itinéraire A* sur le graphe + trajectoire de manœuvre :
      changement de voie, dépassement, stationnement)
                                                      │
                                                      ▼
   ⑦ Contrôle  (IDM = accélération/freinage longitudinal, MOBIL = décision
      changement de voie, poursuite de trajectoire latérale)
                                                      │
                                                      ▼
   ⑧ Couche de sécurité formelle (inspirée RSS + SFF)  — VETO INDÉPENDANT
      distances sûres, priorité non respectée par autrui, visibilité réduite,
      "claimed sets" des objets proches → peut toujours freiner/corriger
                                                      │
                                                      ▼
   ⑨ Actuation  (ai.* / contrôle direct throttle-brake-steer, clignotants,
      warnings, klaxon, phares — Vehicle Lua)
```

Ce découpage reprend directement le pipeline CARLA Traffic Manager (étages indépendants) et l'idée d'Apollo/Mobileye/NVIDIA d'une **couche de sécurité séparée qui peut tout annuler**, quelle que soit la décision prise plus haut.

### 4.2 Le graphe routier sémantique — le cœur du système

Puisque BeamNG ne fournit pas nativement les priorités et limitations par segment, on construit un fichier de données par carte, généré une fois (outil Python offline) puis chargé en jeu (Lua). Schéma indicatif, inspiré d'OpenDRIVE/OSM :

```json
{
  "map": "west_coast_usa",
  "ruleset": "usa_4way_stop",
  "segments": [
    {
      "id": "seg_0142",
      "roadClass": "residential",
      "lanes": { "forward": 1, "backward": 1 },
      "oneWay": false,
      "speedLimit": 40,
      "busLane": false,
      "cycleLane": false
    }
  ],
  "parkingZones": [
    {
      "id": "pk_0014",
      "type": "onStreet | lot | garage",
      "segmentId": "seg_0142",
      "capacity": 6,
      "spots": [
        { "id": "pk_0014_s3", "position": [0, 0, 0], "occupiedBy": null }
      ]
    }
  ],
  "junctions": [
    {
      "id": "j_0031",
      "type": "uncontrolled | stop | trafficLight | roundabout | priorityRoad | railwayCrossing",
      "priorityRule": "rightOfWay | fourWayStop | allWayYield | signalized",
      "approaches": [
        { "segmentId": "seg_0142", "yieldTo": ["seg_0089"], "stopLine": [x, y, z] }
      ],
      "trafficLightGroupId": "tl_0007"
    }
  ]
}
```

Le champ `ruleset` permet de charger un jeu de règles par pays/carte (voir section 6) : c'est ce qui permet à la même IA de rouler à droite avec priorité à droite implicite en France, et à gauche avec priorité systématique à l'anneau en rond-point britannique.

**Génération — validé sur les cartes officielles** : contrairement à l'hypothèse initiale, l'extraction ne nécessite ni BeamNGpy ni instance du jeu en cours d'exécution. Les fichiers `.zip` de carte (`content/levels/*.zip`) contiennent déjà, en JSON brut lisible statiquement :
- des objets `DecalRoad` dans les innombrables `items.level.json` du niveau (format JSON-lines, un objet par ligne) — chaque route porte `nodes` (spline de points `[x,y,z,largeur]`), `oneWay`, `lanesLeft`, `drivability`, `material` ;
- un fichier `levels/<carte>/signals.json` avec trois tables : `controllers` (cycles vert/jaune/rouge d'une phase), `instances` (feux physiques individuels — position, direction, `controllerId`, `group` qui rattache plusieurs têtes de feu à une même intersection), et `sequences` (chorégraphie entre phases d'une même intersection).

Le script `tools/extract_road_graph.py` (aucune dépendance externe, stdlib uniquement) implémente cette première passe : il regroupe les extrémités de segments proches en intersections candidates, puis apparie chaque groupe de feux (`instances[].group`) à l'intersection la plus proche. Testé avec succès sur les cartes officielles `gridmap_v2` (zone `zone_AI_city`, dédiée aux tests d'IA), `west_coast_usa` (12 721 segments, 185 intersections appariées à des feux), `italy` et `Utah`.

**Deux affinages déjà apportés après validation sur les cartes officielles** :
1. La grande majorité des objets `DecalRoad` d'une carte ne sont pas des routes navigables mais des décalques cosmétiques (peinture au sol `line_white`/`line_yellow`, fissures, traces de pneus, caniveaux, passages piétons peints…) posés sur la vraie surface de route. Confirmé empiriquement sur `west_coast_usa` (12 721 `DecalRoad` au total) : la couche de navigation IA utilise systématiquement, sur toutes les cartes testées, le matériau `road_invisible` (1 303 segments pour `west_coast_usa`, contre 12 721 sans filtre) — c'est le seul filtre fiable trouvé pour isoler les routes réellement empruntables par l'IA.
2. Le regroupement d'extrémités proches en carrefour est complété par une comparaison de cap (`classify_cluster`) : si exactement deux segments se rencontrent avec des tangentes quasi opposées (>150°), c'est qu'une route continue simplement en ligne droite (découpée en plusieurs `DecalRoad` consécutifs) — classé `continuation`, pas un vrai carrefour.

Résultat sur `west_coast_usa` après ces deux filtres : 1 303 segments réels, 646 candidats, dont 337 vrais carrefours + 130 carrefours à feux (130, contre 185 avant filtrage — l'ancien chiffre incluait des faux positifs près de décors) + 179 continuations écartées.

**Limite restante** : le type de priorité (stop / cédez-le-passage / priorité à droite) des « vrais carrefours » non signalés reste `null` — cette donnée n'est encodée nulle part nativement. La proposer par défaut selon la hiérarchie `roadClass` (déjà calculée par heuristique de largeur, à l'image de la hiérarchie implicite `highway=*` d'OSM) puis la corriger à la main via une petite webapp locale reste la prochaine étape. Pour les cartes importées depuis OpenStreetMap (pipeline inspiré de MapNG), les tags `highway`, `maxspeed`, `oneway`, `junction=roundabout`, `traffic_signals`, `highway=stop` vs `give_way`, `priority_road` alimenteront directement ce schéma, quasi automatiquement.

### 4.3 Décision — Behavior Tree plutôt que FSM rigide

Arbre de comportement plutôt qu'une simple machine à états, pour permettre l'interruption réactive (ex. un obstacle apparaît pendant une manœuvre de dépassement). États haut niveau principaux : `SuivreVoie`, `ApprocheIntersection`, `Céder`, `Arrêt`, `Tourner`, `Dépasser`, `Fusionner`, `ChercherPlace`, `Stationner`, `SortirDeStationnement`, `DemiTour`, `RéagirUrgence`, `SuivreDéviation`, `Immobilisé` (panne/accident).

### 4.3bis Cycle de vie de la population — stationnement ↔ circulation

Un point identifié en recherche (section 2.1) : BeamNGpy expose `traffic.reset()`, qui **téléporte** les véhicules de trafic loin du joueur pour gérer le flux — un mécanisme probablement responsable d'une partie des plaintes communautaires sur les téléportations/rubber-banding. BeamAI remplace explicitement ce mécanisme par un cycle de vie visible et continu, plutôt que par du spawn/despawn hors champ.

**Principe** : une part significative de la population de véhicules démarre **garée** (dans une zone de stationnement du graphe sémantique, cf. `parkingZones` ci-dessus) plutôt qu'en circulation. Chaque véhicule garé est un agent à part entière avec son propre cycle :

```
Garé (inactif, durée aléatoire pondérée par l'heure simulée)
        │  décision de départ (planificateur de population, GE Lua)
        ▼
Préparation au départ (clignotant, contrôle visuel, vérification trafic)
        │
        ▼
Circulation (le même pipeline ①-⑨ que tout véhicule IA, avec une destination)
        │  arrivée à destination ou fin de trajet
        ▼
Recherche de stationnement (ChercherPlace → Stationner, section 7.F)
        │
        ▼
Garé (inactif) ──── boucle ────
```

Symétriquement, un véhicule en circulation qui ne trouve pas de place disponible peut prolonger son trajet (re-routage vers une autre zone de stationnement) plutôt que de disparaître.

**Gestionnaire de population** (Game Engine Lua) : maintient une densité cible de véhicules actifs sur la carte (paramètre utilisateur, section 7.L) et programme les départs des véhicules garés en conséquence — plus de départs simulés aux heures de pointe (section 7.I), moins la nuit. C'est l'équivalent conceptuel de la génération de trajets par matrice OD de SUMO (`od2trips`/`randomTrips.py`), à la différence que l'origine et la destination sont des **places de stationnement réellement visibles dans le monde**, jamais des points de spawn hors champ. Bénéfice direct : la recherche d'une place de stationnement (section 7.F) devient significative, puisque l'occupation des places évolue réellement au lieu d'être un décor statique.

### 4.4 Contrôle — IDM + MOBIL

- **Longitudinal (IDM)** : `a = a_max × [1 − (v/v0)^δ − (s*/s)²]`, avec `s* = s0 + v·T + v·Δv / (2√(a_max·b))`. Remplace un simple PID par un modèle sans collision, avec des paramètres directement interprétables (temps intervéhiculaire `T`, distance à l'arrêt `s0`) qui **varient par personnalité de conducteur** (section 7.I).
- **Latéral (MOBIL)** : un changement de voie n'est déclenché que si (a) le critère de sécurité est respecté pour le véhicule suiveur de la voie cible, et (b) le gain d'accélération propre dépasse la perte imposée aux autres, pondérée par un **facteur de politesse** — c'est ce paramètre qui différencie un conducteur courtois d'un conducteur égoïste.

### 4.4bis Changement de cap — pilotage 100 % maison, plus aucune dépendance à l'IA native

Décision de conception explicite (pas une contrainte technique) : BeamAI ne s'appuie plus du tout sur `ai.lua` pour décider quoi que ce soit — ni la vitesse (`ai.setSpeed`), ni la trajectoire (`ai.laneChange`/`side_avoidance` natif). Le code source de `ai.lua` reste une référence de lecture (quels paramètres un bon pilotage doit prendre en compte), jamais un moteur de décision. Deux raisons à ce choix :
1. L'IA native de BeamNG est explicitement le problème que ce projet cherche à remplacer — s'appuyer dessus pour la décision, même partiellement, plafonne la qualité atteignable à ce que l'IA native permet déjà.
2. Le premier essai d'évitement (section 8, phase 3) qui boostait `awarenessForceCoef` de l'évitement natif fonctionnait ("oui il esquive") mais restait, par construction, limité par la logique native — jugé insuffisant au regard de l'ambition du projet (niveau Waymo/GTA V/Tesla FSD/Forza).

**Canal de contrôle bas niveau** : `ai.lua` lui-même ne pilote jamais le véhicule autrement qu'en appelant `input.event(itype, ivalue, "FILTER_AI", nil, nil, nil, "ai")` (`lua/vehicle/input.lua`, `FILTER_AI` défini dans `lua/common/inputFilters.lua`) pour les types `"steering"` [-1,1], `"throttle"` [0,1], `"brake"` [0,1]. C'est donc un canal stable et déjà conçu pour être piloté par un système externe à l'humain. BeamAI envoie `ai.setMode('disabled')` une fois par véhicule (ce qui, côté `ai.lua`, met `M.updateGFX = nop` après avoir remis les commandes à zéro — l'IA native cesse alors définitivement d'appeler `driveCar()`, donc plus aucun risque de conflit entre les deux sources de contrôle), puis injecte lui-même `input.event(...)` à chaque tick via `queueLuaCommand`.

**Deux contrôleurs maison, écrits et testés unitairement en dehors de toute dépendance BeamNG** :
- `steeringController.lua` — **pure pursuit** : point de visée calculé sur notre propre graphe routier (`roadGraph.findLookaheadPoint`, distance de visée qui augmente avec la vitesse), transformé dans le repère du véhicule, angle de braquage `atan(wheelbase × 2sin(α)/distance)` normalisé.
- `speedController.lua` — **PID** classique (anti-windup inclus) qui convertit l'écart à la vitesse cible IDM en accélérateur/frein, mutuellement exclusifs.

**État** : validé uniquement par tests unitaires (simulation en boucle fermée comprise) — **jamais testé en jeu** à ce stade, activable via `core.beamai_core.setFullControlEnabled(true)` (voir Test 5 du README). C'est le changement le plus risqué du projet à ce jour : sans IA native active, aucun filet de sécurité ne rattrape une erreur de calcul de direction.

**Conséquence directe sur la suite de la roadmap** : toutes les phases futures (intersections, évitement, urgence, stationnement) devront être implémentées comme des couches au-dessus de ce pilotage maison — jamais comme des appels à des fonctions natives de décision (`ai.setSpeed`, `ai.laneChange`, `ai.driveInLane`, etc.). L'évitement d'obstacle en particulier devra être réimplémenté en déplaçant latéralement le point de visée du pure pursuit (ou un point dédié), plutôt qu'en boostant l'évitement natif — chantier non commencé (voir section 8, phase 3).

### 4.5 Couche de sécurité — inspirée RSS + SFF

Indépendante de la décision haut niveau, elle tourne à chaque frame et **peut toujours freiner ou corriger**, même si le Behavior Tree a décidé autre chose :
- distance longitudinale/latérale minimale garantissant l'arrêt sans collision (formule RSS) ;
- détection de "priorité reçue mais non respectée par un autre véhicule" → prudence même si on a normalement la priorité (principe RSS n°3) ;
- prudence automatique en cas d'occlusion (véhicule garé masquant un croisement, virage sans visibilité) ;
- calcul simplifié de "claimed set" (zone qu'un véhicule proche occuperait en freinage d'urgence) pour arbitrer les cas de dépassement/insertion limite.

---

## 5. Stack technique & outils

| Outil | Rôle | Pourquoi |
|---|---|---|
| **Lua (Game Engine Lua)** | Orchestration globale : chargement du graphe sémantique, gestion des feux (`trafficSignals.lua` étendu), spawn/densité, synchronisation d'incidents (accidents, travaux) | C'est la seule couche capable de coordonner *entre* véhicules (priorités, négociation d'intersection) |
| **Lua (Vehicle Lua)** | Boucle de contrôle par véhicule : perception, BT de décision, IDM/MOBIL, couche de sécurité, actuation | Isolation par véhicule déjà fournie par le moteur ; c'est l'approche validée par les mods existants (Advanced Traffic AI, Traffic Reborn) |
| **Python (stdlib)** | Extraction du graphe routier sémantique directement depuis les `.zip` de carte (`tools/extract_road_graph.py`, validé sur cartes officielles) | Aucune dépendance : DecalRoad et signals.json sont du JSON statique, lisible sans lancer le jeu ni BeamNG.tech |
| **Python + BeamNGpy** | Outillage *hors-ligne* nécessitant une instance du jeu : pipeline d'import OpenStreetMap (inspiré de MapNG), capture de replays humains pour calibration, suite de tests de scénarios automatisés, génération de rapports de régression | BeamNGpy n'est pas adapté au pilotage temps réel de tout un flux de trafic (latence réseau par step) mais est excellent pour la préparation de données et les tests hors-jeu |
| **JSON (schéma maison inspiré OpenDRIVE/OSM)** | Format du graphe routier sémantique et des rulesets par pays | Simple à charger en Lua, versionnable, lisible/éditable à la main si besoin |
| **DSL de scénarios (JSON, inspiré OpenSCENARIO/Scenic de CARLA)** | Décrire des scénarios de test reproductibles : *"véhicule arrive à un stop, un piéton traverse, un véhicule prioritaire arrive de gauche"* | Permet une non-régression automatisée à chaque évolution du moteur de décision |
| **Petite webapp locale (HTML/JS sans build, servie en local)** | Éditeur visuel du graphe sémantique + visualiseur de debug (état du Behavior Tree, zones de sécurité RSS, prédictions) alimenté par un flux BeamNGpy | Débogage bien plus rapide qu'en lisant des logs Lua |
| **Git** | Versionnement du mod et des données de carte | Le dossier projet n'est pas encore un dépôt — à initialiser avant la première ligne de code |
| **Datasets réels (Waymo Open Dataset, highD, INTERACTION)** — *phase ultérieure uniquement* | Calibrer les paramètres IDM/MOBIL (écarts, temps de réaction, vitesses d'insertion) sur des distributions réelles, sans reproduire de matériel | Utilisé pour affiner, jamais comme dépendance de base — le socle reste des modèles formels interprétables |

Volontairement **pas de dépendance ML lourde en v1** (pas d'entraînement de réseau de neurones nécessaire au départ) : le socle règles + IDM/MOBIL/RSS est interprétable, débogable et suffit à couvrir la quasi-totalité des fonctionnalités demandées. L'apprentissage par imitation/renforcement est réservé à la phase 7 (calibration fine, cas rares), en "mode shadow" (le nouveau modèle tourne en silence à côté de l'ancien avant bascule — idée reprise de Tesla).

---

## 6. Localisation par pays / par carte

Le `ruleset` du graphe sémantique encode les variantes nationales du code de la route, avec un système par défaut selon la carte :

| Paramètre | France / Europe continentale | USA | UK / conduite à gauche |
|---|---|---|---|
| Sens de circulation | Droite | Droite | Gauche |
| Intersection non signalée | Priorité à droite implicite | Généralement "4-way stop" explicite | Cédez le passage implicite à l'anneau (giratoire quasi systématique) |
| Panneau STOP | Arrêt obligatoire même sans trafic visible | Idem, très répandu ("all-way stop") | Plus rare, "Give Way" privilégié |
| Rond-point | Priorité à l'anneau (véhicule déjà engagé) | Peu fréquent, règles variables par État | Priorité à l'anneau, sens inversé |
| Dépassement par la droite sur autoroute | Interdit | Toléré dans certains États (voies multiples) | Interdit |
| Vitesse par défaut (agglomération / route / autoroute) | 50 / 80-90 / 130 km/h | Variable par État (mph) | 30 / 60 mph / 70 mph |

Pour une carte officielle BeamNG (ex. West Coast USA, Italy, Utah), le ruleset par défaut est déduit du cadre géographique fictif de la carte. Pour une carte importée depuis OpenStreetMap via le pipeline d'import, le ruleset peut être déduit automatiquement du pays réel (code ISO) associé à l'export OSM.

---

## 7. Liste exhaustive des fonctionnalités

### A. Signalisation & priorités
- Feux tricolores (fixes, actués par flux façon SUMO "actuated", clignotants orange la nuit, flèches directionnelles)
- Panneaux stop (arrêt complet obligatoire, y compris sans trafic visible)
- Cédez le passage
- Priorité à droite (règle française implicite aux intersections non signalées)
- Ronds-points (simples, à plusieurs voies, mini-giratoires, sens selon pays)
- Passages à niveau (arrêt si barrière/feu actif)
- Panneaux de route prioritaire (axe qui n'a pas à céder aux intersections secondaires)
- Zones 30 / zones scolaires (vitesse réduite, vigilance accrue)
- Sens interdits
- Voies de bus / voies réservées covoiturage
- Pistes cyclables et distance latérale de sécurité aux vélos
- Lignes continues / discontinues (interdiction de franchissement, dépassement)
- Interdiction de dépasser par la droite sur autoroute (selon pays)

### B. Vitesse & adaptation environnementale
- Respect des limitations par type de route et par pays
- Adaptation à la météo (pluie, neige, brouillard, verglas) — en s'appuyant sur l'adhérence réelle calculée par la physique BeamNG plutôt qu'une règle arbitraire
- Adaptation à la luminosité (nuit, crépuscule) et gestion automatique des feux (croisement/route, antibrouillard)
- Réduction de vitesse en virage, en zone de travaux, en zone scolaire, par visibilité réduite
- Distance de sécurité dynamique selon vitesse, adhérence et type de véhicule (poids lourd = distance plus grande)

### C. Comportement de conduite
- Utilisation systématique des clignotants (y compris pour sortir d'un rond-point)
- Contrôle visuel / vérification d'angle mort avant changement de voie ou tourne-à-gauche (matérialisé par un délai de "vérification" avant la manœuvre)
- Dépassement intelligent (espace disponible, vitesse relative, marquage au sol, visibilité, retour de voie une fois la manœuvre terminée)
- Fusion et insertion sur voie rapide (adaptation de vitesse en accélération sur bretelle)
- Changement de voie naturel (MOBIL), pas de zigzag
- Conduite fluide, anti-à-coups (accélération/freinage progressifs)
- Redémarrage en côte sans recul
- Respect des distances de sécurité en peloton (platooning naturel, pas scripté)

### D. Gestion du trafic & congestion
- Formation réaliste de bouchons "accordéon" (émergente du modèle IDM, pas scriptée)
- Réaction en chaîne réaliste au freinage
- Re-routage dynamique en cas de bouchon, accident ou route fermée détectés
- Feux adaptatifs au flux réel (extension de phase façon SUMO "actuated")
- Contournement intelligent d'obstacles (véhicule à l'arrêt, débris, animal) — ✅ premier incrément fait (section 8, phase 3) : décalage latéral du point de visée vers le côté confirmé dégagé
- **Contournement d'un obstacle non plus seulement à l'arrêt, mais en mouvement lent** (dépassement classique sur route à double sens) : nécessite un modèle d'acceptation de créneau ("gap acceptance") sur la voie opposée — pas juste une photo instantanée des positions (ce que fait `isOffsetPathClear` aujourd'hui) mais une extrapolation de trajectoire du trafic venant en face sur la durée de la manœuvre, façon modèle de dépassement de SUMO/Krauss
- Comportement adapté au type de véhicule pendant la congestion : poids lourds évitant les rues étroites/résidentielles (routage conscient du gabarit), bus suivant un itinéraire fixe avec arrêts programmés plutôt qu'une destination aléatoire

### E. Situations d'urgence & incidents
- Détection d'accident (choc détecté via les données de dégâts du véhicule)
- Appel automatique des secours avec dépêche réaliste (police / ambulance / pompiers / dépanneuse, temps de trajet simulé)
- Réaction des autres véhicules à un accident (ralentissement d'observation "rubbernecking", dégagement de la voie)
- Cession de passage aux véhicules prioritaires (sirène + gyrophare détectés ; possibilité de feux qui passent au vert pour un véhicule d'urgence, comme les systèmes de priorité feux réels)
- Gestion des zones de travaux (déviation dynamique, réduction de voie, limitation de vitesse locale)
- Gestion des routes fermées (re-routage automatique de tout le trafic concerné)
- Gestion des pannes (immobilisation sur bande d'arrêt d'urgence, feux de détresse, dépanneuse)

### F. Stationnement & manœuvres
- **Alternance stationnement ↔ circulation** : un véhicule garé peut, à un moment choisi par le gestionnaire de population, quitter sa place et rejoindre le trafic ; un véhicule en circulation termine son trajet en cherchant une place et en s'y garant durablement (section 4.3bis) — densité de trafic stable, sans spawn/despawn hors champ ni téléportation
- Recherche active d'une place de stationnement libre (occupation réellement dynamique, pas décorative)
- Stationnement en créneau, en bataille, en épi
- Sortie de place de stationnement (contrôle visuel, clignotant, insertion dans le trafic)
- Marche arrière guidée
- Demi-tour intelligent (trois-points ou via une intersection selon l'espace)
- Stationnement en parking couvert / multi-étages
- Dépose-minute (arrêt bref, warnings, redémarrage)

### G. Usagers vulnérables (hors piétons — hors scope du projet)
- Détection des cyclistes avec distance latérale de sécurité (traités comme véhicules légers sur le graphe/pistes cyclables)
- Détection d'animaux (traversée imprévisible, arrêt d'urgence)
- Vigilance accrue près des écoles (bus scolaires avec leurs propres règles d'arrêt obligatoire pour les véhicules suiveurs)

### H. Interaction avec le joueur et les autres IA
- Réaction aux clignotants, appels de phares et klaxon du joueur
- Courtoisie (céder le passage, remerciement par warnings)
- Réaction mesurée à une conduite agressive du joueur (frustration, klaxon, rarement "road rage" mais jamais dangereux)
- Anticipation des erreurs probables des autres conducteurs (marge de sécurité accrue près d'un véhicule qui zigzague ou freine tard)

### I. Personnalités & variabilité
- Profils continus (pas de catégories figées) : agressivité, patience, respect des règles, compétence, distraction/attention
- Styles reconnaissables : pressé, prudent, conducteur âgé, professionnel (chauffeur, livreur, taxi), novice
- Variabilité selon l'heure (trafic dense et nerveux à l'heure de pointe, calme la nuit)
- Véhicules spéciaux à comportement dédié : bus scolaires, poids lourds (angles morts, distances de freinage), véhicules agricoles lents, véhicules d'urgence

### J. Apprentissage, mémoire & calibration
- Apprentissage progressif par calibration à partir de replays de conduite humaine
- Mémorisation d'incidents marquants (accroît la prudence locale après un accident observé à un endroit donné)
- Auto-calibration des paramètres IDM/MOBIL sur des distributions réelles (temps de réaction, écarts, vitesses d'insertion)
- Mode "shadow" : tester une nouvelle version du moteur de décision en silence, en parallèle de l'ancienne, avant bascule

### K. Localisation géographique
- Sens de circulation (droite/gauche) selon la carte
- Règles de priorité par pays (voir section 6)
- Déduction automatique du ruleset pour les cartes importées depuis OpenStreetMap

### L. Outillage développeur & qualité
- Overlay de debug in-game (état du Behavior Tree, vecteurs de perception, zones de sécurité RSS par véhicule sélectionné)
- Suite de scénarios de test automatisés et reproductibles (DSL de scénarios, section 5)
- Mode replay pour analyser un incident a posteriori
- Réglages utilisateur en jeu (curseurs de densité, agressivité globale, niveau de réalisme)
- Compatibilité multijoueur BeamMP (synchronisation de l'état des feux et des priorités, aujourd'hui locale au client)
- Optimisation de performance : simulation comportementale simplifiée pour les véhicules loin du joueur (LOD comportemental, à l'image du "mode hybride physique" de CARLA), budget de calcul plafonné par frame

### M. Prédiction & coordination inter-véhicules (au-delà de ce que Waymo/FSD peuvent faire — avantage structurel de BeamAI)
Waymo et Tesla FSD doivent *prédire* les autres véhicules car ils ne les contrôlent pas. BeamAI, lui, pilote tout le trafic suivi depuis un seul point central (Game Engine Lua) : on peut donc, en plus de prédire (utile pour les véhicules non suivis, ex. le joueur), carrément **coordonner** plusieurs IA entre elles avec une information parfaite — un avantage qu'aucun système réel ne possède, à exploiter explicitement plutôt qu'à ignorer par excès de réalisme.
- **Couche de prédiction (④ dans le pipeline, section 4.1) — actuellement non implémentée** : extrapolation à court terme de la trajectoire des véhicules non gérés par nous (le joueur, un futur trafic natif restant en complément) à partir de la vitesse/cap courants et de l'état des clignotants ; c'est ce qui manque pour un dépassement d'un véhicule en mouvement (voir section D) et pour anticiper un véhicule qui va couper la route à une intersection.
- **Négociation d'intersection par réservation de créneaux** plutôt que purement réactive : à un carrefour non signalé avec plusieurs IA suivies qui arrivent en même temps, réserver un ordre de passage calculé (façon "intersection réservation" académique/CMU) au lieu de faire deviner à chaque véhicule si l'autre va s'arrêter — élimine par construction les hésitations/blocages mutuels que les IA de trafic classiques (dont celle de BeamNG) ont typiquement aux carrefours non protégés.
- Partage d'information entre IA suivies : un véhicule qui détecte un accident/obstacle/ralentissement peut en informer les autres véhicules suivis à proximité (re-routage collectif, section D), plus rapide qu'une détection individuelle répétée par chacun.

---

## 8. Roadmap

| Phase | Contenu | Objectif de sortie |
|---|---|---|
| 0 — fait | Recherche BeamNG/modding, simulateurs comparables, IA réelle & académique | Ce document |
| 1 — Fondations ✅ *validé en jeu, puis étendu au pilotage 100 % maison, ACTIVÉ PAR DÉFAUT* | Extracteur, IDM, lecture des feux, personnalités de base — **premier test réussi sur West Coast, USA** : respecte le code de la route, roule à la bonne vitesse. Corrections post-playtest : anticipation des feux sur plusieurs segments (freinage tardif), filtre de cap pour ne pas confondre trafic traversant et véhicule devant (hésitations aux carrefours). **Changement de cap (section 4.4bis)** : ajout de `steeringController.lua` (pure pursuit) et `speedController.lua` (PID), pilotage direct par `input.event(...)` après `ai.setMode('disabled')` — remplace `ai.setSpeed`/évitement natif. Décision produit explicite : `M.autoFullControlOnStart` bascule tout le trafic dessus automatiquement au chargement d'une carte, sans commande console (`onClientStartMission`) — testé uniquement hors-jeu au moment où ce défaut a été activé | Un véhicule IA suit sa voie, s'arrête aux feux rouges, accélère/freine sans à-coups, **sans dépendre d'aucune décision native de `ai.lua`, pour tout le trafic sans configuration** |
| 2 — Routage & intersections *(le plus gros trou architectural actuel)* | **Prérequis découvert en écrivant ce plan, pas encore posé du tout** : rien ne calcule aujourd'hui de destination ni d'itinéraire pour un véhicule — `findLookaheadPoint` suit juste "tout droit puis continuations" et vise le carrefour lui-même dès qu'un vrai choix de direction se présente. Sans ça, ni le choix de tourner à un carrefour, ni la recherche de stationnement (phase 6), ni le cycle garé↔circulation (4.3bis) ne peuvent exister. À construire : (a) A* sur le graphe (couche ⑥ Planification, section 4.1) entre segment courant et segment de destination ; (b) `roadGraph` expose la liste des segments sortants d'un vrai carrefour (aujourd'hui seul le cas "continuation" à un seul successeur est géré) ; (c) `findLookaheadPoint` suit la branche choisie par l'itinéraire au lieu de viser le carrefour. Une fois ça posé : priorité à droite / stop / cédez-le-passage (le `priorityRule` du schéma JSON, section 4.2, reste `null` pour l'instant — proposer par défaut via `roadClass` puis affiner à la main), ronds-points (règle "priorité à l'anneau", pas d'arrêt sauf pour s'insérer), négociation multi-véhicules à un carrefour non signalé (départager par ordre d'arrivée à la ligne de stop, façon CARLA FIFO — la réservation de créneaux de la section M est une extension possible une fois le FIFO fiable), tourne-à-gauche non protégé avec acceptation de créneau sur le trafic venant en face (dépend de la couche de prédiction, phase 3bis), passages à niveau (même mécanisme que `trafficLights.lua`, classification différente) | Un véhicule IA a une destination, calcule un chemin, et négocie correctement une intersection non signalée avec plusieurs autres IA |
| 3 — Comportement avancé *(évitement d'obstacle à l'arrêt fait, testé unitairement, bug de conception corrigé avant même le premier test en jeu)* | ~~Évitement latéral via `ai.laneChange`~~ abandonné après test : sans effet visible. ~~Boost de l'évitement natif (`awarenessForceCoef`)~~ fonctionnait ("oui il esquive") mais **rejeté explicitement par choix de conception** (section 4.4bis). **Fait** : `updateFullControlAvoidance` (core.lua) décale progressivement le point de visée du pure pursuit vers le côté confirmé dégagé (`roadGraph.isOffsetPathClear`, `roadGraph.offsetPointLateral`), transition en douceur (`avoidance.currentOffsetMetres`) ; si aucun côté n'est dégagé, retente au tick suivant. **Bug corrigé** : `isOffsetPathClear` incluait l'obstacle lui-même dans la vérification de dégagement (quasiment toujours plus proche que `minClearance` du point de visée décalé) — le véhicule freinait donc jusqu'à l'arrêt derrière l'obstacle dans la plupart des cas au lieu de le contourner, exactement le même bug déjà rencontré une première fois sur l'ancien système (section 10, point 10). `findLeaderOnSegment` retourne maintenant l'id du meneur pour l'exclure explicitement. Reste : fusion sur voie rapide, clignotants réels (API à confirmer), contrôles visuels avant manœuvre | Trafic fluide sur route à deux voies avec dépassements crédibles, entièrement piloté par notre propre contrôleur |
| 3bis — Prédiction *(couche ④ du pipeline section 4.1, non implémentée du tout aujourd'hui)* | Aujourd'hui la décision est purement réactive : `isOffsetPathClear` ne regarde qu'une photo instantanée des positions, pas où les autres véhicules **seront** pendant la manœuvre. Pour un dépassement d'un véhicule en mouvement (pas seulement à l'arrêt, voir section D) et pour anticiper un véhicule qui va couper la route à un carrefour, il faut extrapoler : position future à vitesse/cap constants à court terme, plus tard enrichi par l'état des clignotants comme indice d'intention. Sert aussi à mieux gérer le joueur (non suivi par ce mod, donc son comportement doit être *prédit*, jamais contrôlé) | Le contournement et les décisions à un carrefour tiennent compte de la trajectoire probable des autres véhicules, pas seulement de leur position actuelle |
| 4 — Sécurité & incidents | Couche RSS/SFF (section 4.5) comme **veto indépendant** — n'existe pas encore en tant que module séparé : aujourd'hui la sécurité est un sous-produit d'IDM + de la vérification de dégagement, pas une couche qui peut annuler explicitement n'importe quelle décision. Détection d'accident (données de dégâts du véhicule, API à confirmer), dépêche des secours, réaction en chaîne des autres véhicules (ralentissement d'observation, dégagement de voie), cession de passage aux véhicules d'urgence (détection sirène/gyrophare — API à confirmer), zones de travaux et routes fermées (dépend du routage de la phase 2 pour re-router), pannes (immobilisation, feux de détresse) | Un accident déclenche une réaction réaliste en chaîne, et aucune décision du Behavior Tree ne peut jamais produire une collision évitable |
| 5 — Usagers vulnérables (hors piétons, choix de scope) | Cyclistes et animaux traités comme des véhicules légers sur le même graphe (aucun support IA natif à créer, juste un profil dédié + distance latérale de sécurité plus généreuse) ; vigilance accrue près des bus scolaires (arrêt obligatoire pour les suiveurs, à modéliser comme un feu rouge temporaire) | Cyclistes respectés avec distance latérale de sécurité, sans travail de perception supplémentaire |
| 6 — Stationnement & alternance *(dépend du routage, phase 2)* | Le schéma `parkingZones` existe dans la spec JSON (section 4.2) mais **`tools/extract_road_graph.py` ne détecte encore aucune zone de stationnement** — à ajouter à l'extracteur en premier. Puis : gestionnaire de population (4.3bis, GE Lua, densité cible par heure simulée), recherche de place libre parmi les zones du graphe, manœuvre de stationnement réelle (créneau/bataille/épi — un vrai problème de planification locale, probablement le plus dur de tout le projet après le routage : hybrid-A* ou une bibliothèque de manœuvres géométriques prédéfinies plutôt que du pure-pursuit brut), sortie de place et insertion dans le trafic, demi-tour intelligent | Un véhicule IA se gare, repart plus tard rejoindre le trafic, et un véhicule en circulation trouve une place et s'y installe durablement — plus de spawn/despawn hors champ |
| 7 — Personnalités & apprentissage *(socle posé)* | ~~Profils de base (vitesse, distance de suivi, non-respect occasionnel des feux)~~ fait — `driverProfile.lua`, testé unitairement. Reste : profils continus plus riches (compétence, distraction), véhicules spéciaux à comportement dédié (poids lourds, bus, véhicules agricoles lents), calibration sur replays humains (nécessite d'abord un système d'enregistrement, non construit), mode "shadow" (nécessite de faire tourner deux moteurs de décision en parallèle sans que le second ne pilote réellement le véhicule — non trivial architecturalement) | Diversité de styles de conduite perceptible, y compris entre catégories de véhicules |
| 8 — Localisation | Le champ `ruleset` existe dans le schéma du graphe (section 4.2) **mais n'est lu nulle part dans le code Lua actuel** — `driverProfile`/`core.lua` ne consultent aucune règle par pays aujourd'hui, tout est actuellement un unique jeu de règles implicite. À construire : chargement effectif du ruleset, priorité à droite vs 4-way-stop vs give-way selon le pays, sens de circulation, déduction automatique depuis un export OpenStreetMap (code ISO) | Une vraie ville importée se comporte selon ses propres règles, sans code spécifique par carte |
| 9 — Coordination avancée & échelle *(section M — va au-delà de ce que Waymo/FSD peuvent faire, exploite l'avantage structurel de contrôler tout le trafic depuis un seul point)* | Négociation d'intersection par réservation de créneaux plutôt que purement réactive (une fois le FIFO de la phase 2 validé) ; partage d'information entre IA suivies (accident/ralentissement détecté par une IA informe les autres à proximité) ; perf à grande échelle (LOD comportemental façon "mode hybride physique" de CARLA, budget de calcul plafonné par frame) ; multijoueur BeamMP (synchronisation de l'état des feux/priorités, aujourd'hui locale au client) ; overlay de debug in-game, DSL de scénarios de test reproductibles, mode replay, réglages utilisateur (densité, agressivité, réalisme) | Un trafic qui coordonne mieux ses intersections qu'un système réel ne le pourrait jamais (information parfaite entre agents), à grande échelle, mod jouable en conditions réelles |

---

## 9. Risques et limites assumées

- **Moteur fermé** : le solveur physique et le rendu restent une boîte noire ; toute la logique de BeamAI vit dans la couche Lua/data, ce qui est suffisant d'après les mods existants mais impose des contraintes de performance non documentées officiellement (nombre max de véhicules IA simultanés inconnu).
- **Cyclistes/animaux** : aucun comportement IA natif, mais traitables comme des véhicules légers sur le même graphe — coût nettement réduit depuis que les piétons ont été sortis du périmètre (choix produit).
- **Multijoueur (BeamMP)** : l'état des feux est aujourd'hui local au client ; une IA de trafic cohérente en réseau demandera une synchronisation dédiée, non résolue par le jeu de base.
- **Mises à jour BeamNG** : les chemins de fichiers internes (`trafficSignals.lua`, structure des mods) peuvent changer d'une version à l'autre ; prévoir une couche d'abstraction fine entre BeamAI et l'API du jeu.
- **Écart volontaire au réalisme technique** : le simulateur donne une vérité terrain parfaite ; BeamAI doit *dégrader délibérément* cette information (temps de réaction, angles morts simulés) pour rester crédible humainement — un choix de conception à assumer, pas un compromis technique subi.

---

## 10. Prochaine étape concrète

1. ~~Initialiser un dépôt Git pour le projet.~~ Fait — [github.com/Thomas-TP/BeamAI](https://github.com/Thomas-TP/BeamAI).
2. ~~Écrire le script Python d'extraction du graphe routier.~~ Fait — `tools/extract_road_graph.py`, validé sur `gridmap_v2`, `west_coast_usa`, `italy`, `Utah` sans dépendance externe.
3. ~~Affiner la détection de jonctions~~ Fait — filtrage sur le matériau `road_invisible` (élimine les décalques cosmétiques) + comparaison de cap pour distinguer une vraie divergence d'une simple continuation de route ; `roadClass`/`speedLimit` assignés par heuristique de largeur.
4. ~~Écrire le module IDM (`mod/lua/ge/extensions/beamai/idm.lua`)~~ Fait — testé unitairement en Lua (5 scénarios, y compris une simulation complète d'arrêt sans collision).
5. ~~Écrire le module de graphe routier (`roadGraph.lua`) et l'orchestrateur (`core.lua`)~~ Fait — géométrie (`closestPointOnPolyline`, `distanceAlong`) testée unitairement ; `core.lua` orchestre déjà la boucle IDM sur une voie sans intersection mais **n'a pas encore été validé en jeu** (voir avertissement en tête de fichier et `README.md`).
6. ~~Câbler la lecture de l'état des feux~~ Fait — `trafficLights.lua` interroge `extensions.core_trafficSignals` plutôt que de re-simuler le cycle localement (choix motivé : ne pas risquer un décalage avec le vrai feu affiché au joueur). Échoue en sécurité : un état illisible est traité comme rouge, jamais comme vert.
7. ~~Deviner l'API du jeu~~ **Devenu inutile** — le jeu installé expose ses propres scripts Lua en clair sur le disque (`<install>/lua/...`, hors des `.zip`). Lu directement le vrai code source de `lua/ge/ge_utils.lua`, `lua/ge/extensions/core/vehicles.lua`, `lua/vehicle/ai.lua` et `lua/ge/extensions/core/trafficSignals.lua` : tous les appels d'API de `core.lua`/`trafficLights.lua`/`roadGraph.lua` sont maintenant vérifiés contre le vrai code, plus des suppositions. Un bug réel a été corrigé au passage (`ai.setSpeed` ne prend qu'un argument ; `ai.setSpeedMode` est un appel séparé) et `roadGraph.loadGraph` utilise maintenant `jsonReadFile` (confirmé) au lieu de `readFile`+`jsonDecode` (deviné).
8. ~~Automatiser le test~~ Fait — `core.lua` détecte le chargement de `west_coast_usa` (`onClientStartMission`), charge automatiquement un graphe embarqué dans le mod, enregistre tous les véhicules et rescanne toutes les 3s (aucune commande console requise). Package prêt : `dist/beamai.zip`.
9. ~~Premier test en jeu~~ **Réussi** — sur West Coast, USA : respecte le code de la route, roule à la bonne vitesse. Trois points remontés par ce playtest, tous corrigés :
   - Freinage tardif aux feux → `roadGraph.findUpcomingTrafficLight` anticipe désormais à travers plusieurs segments consécutifs (au lieu de ne regarder que la fin du segment courant).
   - Hésitation en tournant à un carrefour (prend peur d'un véhicule qui n'a pas fini de traverser) → `roadGraph.isPlausibleLeader` filtre le trafic traversant par alignement de cap, ne garde que ce qui roule vraiment dans notre sens.
   - Demandé : personnalités de conducteurs (plus/moins rapides, non-respect occasionnel des feux) → `driverProfile.lua` ajouté (profil tiré une fois par véhicule, décision de griller un feu tirée une fois par carrefour rencontré pour éviter le flicker).
10. ~~Évitement latéral d'un obstacle~~ Codé (phase 3, premier incrément) :
    - Découverte clé : `ai.laneChange(plan, dist, signedDisp)` existe déjà côté jeu (`lua/vehicle/ai.lua`, exporté), défaut sur la route/le plan du véhicule si `plan` est `nil`, et **borne le déplacement latéral aux limites réelles de la route** (`laneLimLeft`/`laneLimRight`, calculées par le jeu) — pas de risque de sortie de chaussée par construction. Décision de conception : s'appuyer dessus plutôt que de recalculer une trajectoire latérale nous-mêmes.
    - `mobil.lua` : critère de décision (gain/sécurité/politesse, façon Kesting/Treiber/Helbing 2007) + déclencheur spécifique « obstacle proche et quasi à l'arrêt ».
    - `avoidance.lua` : machine à états (idle → décalage → retour) séparée de l'effet de bord (`ai.laneChange`), donc testable unitairement même si le geste réel ne l'est pas depuis cette machine — filet de sécurité par timeout inclus.
    - `roadGraph.isOffsetPathClear` : vérifie qu'aucun autre véhicule suivi ne se trouve sur la trajectoire décalée avant de s'engager.
    - **Point non vérifié** : le sens gauche/droite du décalage signé (cohérent avec lui-même d'un appel à l'autre, mais son sens réel en jeu n'est pas confirmé) et le rendu réel du geste. D'où l'activation **désactivée par défaut** (`setAvoidanceEnabled`) — à tester isolément (Test 4 du README) avant la circulation dense.
11. ~~Blocage de déploiement~~ Résolu — le mod (zip) ne se montait pas dans le système de fichiers virtuel du jeu (`FS:directoryExists` renvoyait `false` malgré un mod « activé » dans le gestionnaire). Cause probable : le vrai dossier utilisateur du jeu sur ce poste n'est pas `Documents\BeamNG.drive\<version>\` comme supposé initialement, mais `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\` — confirmé en lisant `mods/db.json` en jeu. Basculé sur le format **mod « unpacked »** (dossier brut, pas de zip) déposé directement dans `mods/unpacked/beamai/lua/...`, plus simple et qui contourne toute question de montage de zip. Voir `README.md`.
12. Nouveau test en jeu à faire (redémarrage complet du jeu nécessaire après le changement de format de mod) — Test 3 pour les corrections précédentes, Test 4 pour l'esquive.
13. **Pivot vers un pilotage 100 % maison** (section 4.4bis) — demandé explicitement : ne plus s'appuyer sur aucune décision native de `ai.lua`, y compris l'évitement natif du point 10 (qui fonctionnait mais restait dépendant du moteur natif). Écrit et testé unitairement : `steeringController.lua` (pure pursuit), `speedController.lua` (PID), `roadGraph.pointAtDistance`/`findLookaheadPoint` (point de visée qui traverse les segments/continuations), `core.lua` réécrit pour piloter directement `input.event('steering'|'throttle'|'brake', ...)` après `ai.setMode('disabled')`, activable via `setFullControlEnabled(true)`. **Pas encore testé en jeu** — c'est la prochaine étape immédiate (Test 5 du README), à faire sur un seul véhicule isolé avant toute généralisation. Le sens de braquage (`steeringController.STEERING_SIGN`) n'est pas confirmé et devra être ajusté selon le premier retour terrain. L'évitement d'obstacle et le choix de branche à un carrefour restent à réimplémenter sur ce nouveau socle (phase 3 et 2 ci-dessus).
14. **Premier essai de test du pilotage complet et évitement en pilotage complet** :
    - Le premier essai (`extensions.reload("beamai_core")` puis `setFullControlEnabled(true)`, sans le reste de la séquence) **n'a en réalité rien activé** — leçon capturée directement dans l'en-tête de `core.lua` et dans le README (Test 5) pour ne pas reproduire l'erreur : `extensions.reload` remet le module à zéro mais ne redéclenche pas `onClientStartMission`, donc `M.enabled`/`M.graph` restent non définis et `onUpdate` s'arrête à sa première ligne. Rien ne prouve donc encore que le pilotage maison fonctionne ou non — le vrai test reste à faire avec la séquence complète.
    - Bug de conception trouvé en écrivant le protocole de test isolé : le re-scan automatique (`registerAll` toutes les 3s) embarquerait tous les véhicules de la carte dès `setEnabled(true)`, y compris sous pilotage complet déjà actif — contraire à l'intention « un seul véhicule isolé » du Test 5. Corrigé par un nouveau commutateur `M.setAutoScanEnabled(false)`, à couper avant un test isolé.
    - **Fait** (à la demande explicite de continuer à développer sans attendre la validation en jeu) : l'évitement d'obstacle en pilotage complet, sur le nouveau socle — voir la ligne « Comportement avancé » du tableau de la section 8. Testé unitairement uniquement.
15. **Pilotage complet activé par défaut, sans commande console** — demandé explicitement : lancer le jeu et charger une carte supportée doit suffire, tout le trafic (hors véhicule du joueur) doit être piloté par ce mod dès le départ. `M.autoFullControlOnStart` (vrai par défaut) fait basculer `onClientStartMission` sur `setFullControlEnabled(true)` avant `setEnabled(true)`, donc chaque véhicule embarqué par le re-scan automatique reçoit `ai.setMode('disabled')` dès son enregistrement. Bascule manuelle de secours conservée (`setAutoFullControlOnStart(false)`, `setEnabled(false)`) pour revenir à l'ancien pilotage vitesse-seule sans toucher au code. **C'est désormais le tout premier test en conditions réelles de ce pilotage** — jusqu'ici seulement testé unitairement hors-jeu ; le sens de braquage (`STEERING_SIGN`) en particulier n'a jamais été confirmé en jeu.
