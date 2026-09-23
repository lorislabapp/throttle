# Throttle — séparation interfaces / cœur produit

Date : 2026-09-16. Mission : `8A91A20B-0E22-4C28-B2C7-3A767EF7FFDB`.
Base inspectée : `0f53c96882d8ad4caaf07c27efe0b052421999ef`, avec diff local.

## Décision et portée

Kevin a choisi l'option 2 : interfaces ouvertes, cœur propriétaire. La direction
produit est acceptée. La matrice ci-dessous est une proposition technique pour
les futurs composants, et non une déclaration de propriété des fichiers actuels.
La qualification des droits et du matériel déjà publié reste à documenter.

La préparation locale est autorisée par la mission. Les créations de dépôts,
changements de visibilité, déplacements Git, commits et publications conservent
leurs autorisations distinctes. Le présent document ne change pas `LICENSE`.

## Frontière proposée

Deux dépôts de destination sont proposés, sans les créer : `throttle-interfaces`
(public) et `throttle-product` (privé). Les noms sont provisoires. Le produit
dépend d'une révision publiée des interfaces ; les interfaces ne dépendent
d'aucun module du produit.

| Composant | Destination proposée | Source actuelle et travail nécessaire |
|---|---|---|
| Contrats MCP de tâches et exploration | Public, extraction locale réalisée | `Packages/ThrottleMCPContracts/` : huit schémas déclaratifs autonomes et référence JSON de compatibilité. Les adaptateurs du produit consomment cette source ; handlers, décisions et mutations restent dans le produit. |
| Format de messages LAN | Public, extraction locale réalisée | `Packages/ThrottlePeerProtocol/` : package indépendant, Foundation uniquement. `ThrottlePeer` le consomme et conserve un alias public. Examiner la provenance citée dans son commentaire avant distribution. |
| Format du miroir | Public, lecture extraite localement | `Packages/ThrottleMirrorContract/` : données de lecture seules. `ThrottleMirrorSnapshot` compose ce contrat avec `MirrorProvisioning`, conservé dans le produit. Le JSON plat historique est préservé ; fixtures entièrement synthétiques. |
| Contrats du coffre | Public, extraction locale réalisée | `Packages/ThrottleVaultContract/` : format des reçus scellés et validateur, types de requête/réponse, limites et identité de service, Foundation/CryptoKit seulement. `ResearchVaultModel` et `ResearchVaultIPCModel` le réexportent ; état de revue, grant d'endpoint, protocoles NSXPC, client et lecteur d'Inbox restent dans le produit. |
| SDK et CLI d'intégration | Public, client extrait localement | `Packages/ThrottleVaultClient/` : interfaces NSXPC, vérification de l'exigence de signature, fabrique de connexions, client mince et lecteur d'Inbox, construits sur `ThrottleVaultContract` seul (macOS). `ResearchVaultXPCClient` le réexporte et ne garde que les politiques d'endpoint. CLI et exemples restent à écrire ; les exécutables actuels du coffre importent gateway, Keychain ou stockage et ne sont pas exportables. |
| Conformité des protocoles | Public | Extraire les seuls tests de format, de compatibilité et de refus de messages invalides ; fixtures synthétiques. Les tests de bout en bout du produit restent avec le produit. |
| Cockpit, applications et orchestration | Cœur produit | `Throttle/`, `ThrottleiOS/`, widgets, compagnon visionOS : UI, lancement, planning, routage, admission des budgets, revue et effets de release. Extraire les contrats avant de migrer les implémentations. |
| Moteur du coffre | Cœur produit | Raisonnement, ingestion, synthèse, stockage, gateway, Keychain et service XPC dans `Packages/ResearchVaultKit/`. Les schémas clients ne doivent pas importer ces implémentations. |
| Runtime Edge et installation | Cœur produit dans le premier découpage | `edge-agent/` et services Edge dans `ThrottleShared` : garder déploiement et exécution avec le produit. Documenter séparément le protocole destiné aux intégrateurs. |
| Transport, comptes et configuration Apple | Cœur produit | `PeerTLS`, `PeerPairing`, Keychain, mapping CloudKit, identifiants de conteneur et App Group. L'intégrateur reçoit un contrat et une configuration explicite. |
| Données, poids et évaluations internes | Hors distribution publique | Classifier les fixtures et données par provenance. Publier la méthode et les exemples synthétiques ; réserver le corpus d'évaluation interne. |
| Dépendances tierces | Notices et licences propres | Examiner les 21 entrées de dépendances inventoriées ; leur présence dans un futur dépôt privé ne détermine pas leurs droits. |

## Couplages observés

- `ThrottleShared/Package.swift` regroupe contrat du miroir, runtime Edge,
  Keychain et ingestion CFO. Son nom « Shared » ne justifie pas son export entier.
- `ThrottlePeer` dépend de `ThrottleShared`. Le premier package de format LAN
  doit pouvoir se compiler sans cette dépendance globale.
- `ResearchVaultIPCModel` dépendait de `ResearchVaultModel` ; les deux modules
  réexportent désormais `ThrottleVaultContract`. `ResearchVaultMCP` dépend
  toujours de gateway, ingestion et SQLCipher : une copie du package complet
  emporterait le moteur.
- `PlanMCPSchemas` était une extension couplée aux helpers de `PlanMCPTools`.
  Le contrat est désormais canonique dans `ThrottleMCPContracts` ; les helpers
  de déclaration sont extraits et les adaptateurs délèguent au package. Les
  valeurs des modèles métier sont vérifiées contre le contrat par des tests.

## Ordre de migration et critères de passage

1. **Enregistrer la direction** : réalisé par la décision utilisateur et ce
   document. Conserver la revue de droits comme état distinct.
2. **Préparer une extraction locale minimale** : commencer par le format LAN,
   puis ajouter un contrat à la fois. Conserver signatures publiques et octets
   échangés ; l'app utilise un adaptateur temporaire si nécessaire.
3. **Vérifier le package public isolé** : build sans accès au cœur, tests de
   compatibilité entre versions, messages tronqués et tailles excessives. Une
   archive publique utilise une liste positive de fichiers ; aucun export
   automatique de dossiers `Shared`, de fixtures ou de l'historique complet.
4. **Faire consommer ce package au produit** : dépendance unidirectionnelle,
   version exacte, tests macOS/iOS pertinents. Les preuves de la veille restent
   historiques dès qu'un fichier produit change.
5. **Qualifier droits et notices sur les fichiers retenus** : rattacher chaque
   décision à une personne, une référence, une révision et une liste de fichiers.
   Le choix d'option 2 ne remplit pas automatiquement `legalReview.approved`.
6. **Préparer les migrations Git reviewables** : proposer les destinations,
   visibilités, contenu et traitement de l'historique avant toute action distante.
7. **Revalider la release** : CI sur la révision finale, parcours EN/FR et AX,
   appareils et services réels concernés, puis candidat signé et étapes de
   distribution avec leurs preuves propres.

Le découpage technique et la validation UI peuvent avancer avant la fin de la
qualification des droits. Cette dernière bloque la distribution affectée, pas
la préparation locale.

## Preuves et limites de ce jalon

Le format LAN est extrait dans `Packages/ThrottlePeerProtocol/`, sans dépendance
de package. L'implémentation conserve le format existant ; seuls deux noms de
variables locales ont changé pour satisfaire le lint à leur nouvel emplacement.
La provenance mentionnant Weave est conservée. Le module produit `ThrottlePeer`
consomme le package local et réexporte le type par un `typealias` public : les
clients gardent leurs imports, après recompilation. Aucune garantie d'ABI
binaire n'est ajoutée.

Les tests de conformité utilisent des octets littéraux de référence et couvrent
les huit types, les limites entières, les fragments incomplets, les trames
concaténées, les slices et la limite de réception de 4 MiB. Une étape CI dédiée
exécute cette suite. Les empreintes de sources macOS et iOS incluent désormais
le package : ses modifications invalident les preuves antérieures.

Les résultats locaux et commandes sont consignés dans
`docs/testing/2026-09-16-peer-protocol-extraction.md`. La dépendance reste locale
pendant cette préparation ; son épinglage sur une version publiée appartient à
la migration ultérieure. La séparation distante n'est pas réalisée.

Les huit schémas MCP de plan et d'exploration sont extraits dans
`Packages/ThrottleMCPContracts/`. Une référence JSON capturée avant extraction
contrôle la compatibilité complète. `project.yml`, les tests isolés du cœur et
l'empreinte macOS incluent ce module ; les handlers et leur autorisation restent
dans le produit. Les autres familles d'outils MCP ne sont pas extraites dans ce
jalon. Preuves : `docs/testing/2026-09-16-mcp-contract-extraction.md`.

Le contrat du miroir est extrait dans `Packages/ThrottleMirrorContract/` :
`MirrorReadSnapshot`, fenêtres, états et onglets. Il ne stocke ni ne réencode
les cinq champs de provisioning. Le produit compose ce type avec
`MirrorProvisioning` et garde un codec JSON plat compatible avec les compagnons
existants. La politique de nettoyage des chaînes reste dans le produit ;
la projection de lecture seule ne remplace pas cette politique. Preuves :
`docs/testing/2026-09-16-mirror-contract-extraction.md`.

Le contrat client du coffre est extrait dans `Packages/ThrottleVaultContract/` :
format des reçus scellés, types de requête/réponse, limites et identité de
service, sans dépendance de package. Les modules `ResearchVaultModel` et
`ResearchVaultIPCModel` le réexportent ; le JSON de chaque type est identique à
la capture réalisée avant extraction. Les protocoles NSXPC, les politiques
d'endpoint, le client et le lecteur d'Inbox restent dans le produit et forment
la couche transport/SDK, prochaine frontière à traiter. Preuves :
`docs/testing/2026-09-16-vault-contract-extraction.md`.

La couche transport est extraite dans `Packages/ThrottleVaultClient/` :
interfaces NSXPC (sélecteurs identiques à la capture), exigence de signature,
fabrique de connexions, client mince et lecteur d'Inbox. Le produit garde les
politiques d'endpoint et le grant ; le service XPC se conforme aux interfaces
via la réexportation. Preuves :
`docs/testing/2026-09-16-vault-client-extraction.md`.

Prochaine étape : CLI mince et exemples d'intégration sur ce client, puis les
autres frontières réellement nécessaires. La validation globale des
applications suivra sur le graphe final des dépendances.

L'inventaire frais est `audit-output/ip-inventory-20260916-2.json` ; ses chemins
restent `unreviewed` jusqu'à l'application d'une politique qualifiée.
