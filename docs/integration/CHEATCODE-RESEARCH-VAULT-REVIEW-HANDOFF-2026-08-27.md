# Handoff review-only — CheatCode × ResearchVaultKit

- Date : 2026-08-27
- Source : `/Users/kevinnadjarian/GitHub/Throttle/Packages/ResearchVaultKit`
- Cible observée : `/Users/kevinnadjarian/GitHub/CheatCode/CheatCodeSpikes`
- Autorisation : lecture et avis seulement ; **ne rien modifier dans CheatCode**

## Demande à la session CheatCode

Analyser l’adoption de `ResearchVaultKit` sans écrire de code. Vérifier en
priorité la frontière SQLite, les contrats de provenance et la meilleure forme
d’IPC local. Renvoyer un avis `GO / GO WITH CAVEATS / NO-GO` accompagné des
preuves exactes de link-map/runtime nécessaires.

## Pourquoi l’import direct est NO-GO aujourd’hui

CheatCode compile SQLCipher 4.18.0 comme amalgamation unique avec FTS5 et
sqlite-vec (`CheatCodeSQLCore`, `SQLITE_CORE`). `ResearchVaultSQLCipher` utilise
le XCFramework officiel Zetetic 4.18.0. Charger les deux dans le même processus
peut dupliquer les symboles `sqlite3_*`, casser l’hypothèse d’un core unique ou
faire écrire une base avec le mauvais codec.

Ne pas ajouter le produit `ResearchVaultGateway` à CheatCode tant que ce conflit
n’est pas résolu. Les produits purs `ResearchVaultModel` et
`ResearchVaultIngestion` n’embarquent pas SQLCipher, mais ils ne donnent pas à
eux seuls accès au vault chiffré.

## Option recommandée

Un helper local possédé par Throttle :

```text
CheatCode -> IPC local authentifié -> ResearchVault Gateway -> SQLCipher vault
```

- aucun partage de clé ou fichier DB ;
- grants projet/sensibilité fixés côté serveur, jamais fournis par la requête ;
- réponses bornées avec document ID, `library_path`, origins, chunk ordinal et
  SHA-256 plaintext ;
- outils read-only `research_vault_search` et `research_vault_health` au départ ;
- import DeepSearsh/Inbox uniquement par l’owner Throttle ;
- protocole versionné et test de confusion d’identité entre clients.

## Alternatives à évaluer, sans les implémenter

1. Adapter `ResearchVaultStore` au core SQLCipher existant de CheatCode. Cela
   évite un deuxième codec mais duplique les migrations et augmente le couplage.
2. Remplacer l’amalgamation CheatCode par le XCFramework officiel. NO-GO sans
   preuve sqlite-vec/FTS5, benchmarks, migrations et récupération des bases.
3. Processus commun avec un seul core reconfiguré. NO-GO tant que son isolation
   de clés et ses modes de distribution ne sont pas démontrés.

## Gates déjà verts côté Throttle

- Debug et Release : 29 XCTest + 15 Swift Testing, zéro échec ;
- crash process réel écriture/migration, Debug et Release ;
- SQLCipher 4.18.0, mauvais key rejeté, header non plaintext ;
- backup/restore chiffré sous nouvelle clé ;
- DeepSearsh réel : 38 documents Throttle, 440 chunks ;
- benchmark : Recall@5 1.0, MRR 0.867, nDCG@5 0.90, p95 final sous charge
  26.94 ms ;
- vrai processus MCP testé sur 38 documents/440 chunks ;
- bundle final et checksums disponibles dans
  `/private/tmp/research-vault-mcp-20260827-final` ;
- isolation projet/sensibilité et tentatives FTS hostiles testées.

## Questions auxquelles la session CheatCode doit répondre

1. Quel transport IPC local s’intègre le mieux à son architecture actuelle :
   stdio enfant, Unix domain socket ou XPC signé ?
2. Comment lier l’identité du client au grant sans secret en arguments/env ?
3. Quel sous-ensemble de modèles peut être partagé sans exposer SQLCipher ?
4. Quelles preuves de link-map et d’image runtime fermeraient définitivement le
   risque de double SQLite ?
5. Les citations actuelles suffisent-elles à son pipeline RAG/RRF, ou faut-il
   ajouter source observation time et evidence status dans chaque hit ?

## Ce qui reste interdit

- modifier/committer/pousser CheatCode ;
- partager master key, derived key, base, backup ou corpus ;
- laisser un tool call élargir le projet ou la sensibilité ;
- présenter une synthèse locale comme source canonique ;
- annoncer une readiness produit depuis les seules preuves package.

## Mise à jour après la contre-revue CheatCode

La contre-revue est acceptée. Le stdio initial est reclassé `NO-GO` pour toute
livraison inter-app. La branche Throttle contient désormais, sans modification
de CheatCode :

- `ResearchVaultIPCModel`, contrat versionné pur sans SQLCipher/Keychain/ingestion ;
- citations v2 avec observation, modification source, statut de preuve
  optionnel, locator/excerpt hash et génération d'index ;
- `ResearchVaultXPC`, qui compile les requirements via Security.framework,
  authentifie le client au niveau du listener et fournit le pinning réciproque
  côté client ;
- un service nommé query-only, sans arguments, avec grant immuable
  `cheatcode + throttle / internal` pour l'identité
  `com.kevinnadjarian.cheatcode`, Team `TDV6D5L785` ;
- le MCP direct maintenu uniquement comme harness Debug et désactivé en Release ;
- une gate négative empêchant toute dépendance privilégiée Research Vault dans
  la surface cliente ou le package CheatCode observé.

Le nouveau dossier de décision est
`docs/adr/0002-research-vault-authenticated-xpc-boundary.md` et le paquet de
preuves est
`docs/research/2026-08-27-research-vault-authenticated-xpc-boundary.md`.

CheatCode doit rester gelé. Les cibles Xcode/launchd existent désormais dans
Throttle et un bundle Release complet non signé passe le gate de structure et
de linkage : SQLCipher reste dans le helper et n'entre pas dans le processus
Throttle. La matrice signée synthétique est désormais acquise côté Throttle :
service et host Apple Development, pinning réciproque, Team ID faux, mauvais
identifier et confusion de rôle sont tous testés sur une copie isolée.

## Paquet d'acceptation G7 prêt à exécuter

CheatCode doit dépendre uniquement des produits `ResearchVaultIPCModel` et
`ResearchVaultXPCClient`, puis construire le client avec :

```swift
let vault = try ResearchVaultServiceContract.makeCheatCodeClient()
let health = try await vault.health()
let context = try await vault.search(query: query)
```

Ce constructeur est query-only : il épingle
`com.lorislab.throttle.research-vault-agent`, Team `TDV6D5L785`, et ne configure
aucun endpoint owner/import. Les noms Mach et l'identité ne doivent pas être
recopiés dans CheatCode.

Critère binaire G7 cross-app sur une copie isolée signée de CheatCode :

1. `health()` retourne le contrat courant et les checks d'intégrité verts ;
2. `search()` retourne soit des citations v2 autorisées, soit un résultat vide
   valide, sans élargissement de projet ou de sensibilité ;
3. `importReceipts` échoue localement avec `invalidConfiguration` ;
4. le processus CheatCode ne charge aucun SQLCipher provenant de
   `ResearchVaultKit` selon son link-map et ses images runtime ;
5. une identité, un Team ID ou un endpoint de rôle incorrect est rejeté ;
6. l'agent est désenregistré et les processus/copies temporaires sont arrêtés.

## Résultat G7 — 2026-08-28

G7 est PASS sur le Mac physique. Le checkout CheatCode a reçu uniquement un
bridge query-only et les produits `ResearchVaultIPCModel` /
`ResearchVaultXPCClient`. Une copie source isolée a produit le vrai bundle
CheatCode signé Apple Development ; sa matrice app-hosted passe 4/4 : positif,
mauvais rôle, mauvais Team ID et mauvais identifiant client. L'owner reste
indisponible localement et aucun SQLCipher Research Vault n'entre dans le
processus CheatCode. Le checkout actif passe aussi un build Release frais de
`cheatcode-app` et sa suite complète Debug, 447 tests dans 6 suites.

L'agent a été désenregistré après les runs. Aucun commit, push, remplacement
dans `/Applications`, notarisation ou publication n'a été effectué. La prochaine
gate est G8, avec autorisation de distribution séparée obligatoire.
