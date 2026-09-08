# Candidat de qualification 3.6.0

Base : `cdae2c718ac47bbfae19ca2f6fa17ceb077d89d7`. La branche
`qualification/3.6.0-release-loop-ci` ajoute une sélection explicite de correctifs
pour la confidentialité du miroir, les bornes IPC, le staging et les tests/CI.
Le lot PlanStore/diagnostics développé parallèlement n’est pas inclus dans cette
sélection. Sa qualification doit rester distincte.

Preuves locales après durcissement des scripts : 120 tests Python réussis, sept tests du publisher,
26 tests portables du companion, neuf tests de clés projet et 21 tests XPC en
processus. SwiftLint 0.63.2 strict et `git diff --check` passent sur cette sélection.
Les régressions de notification iCloud et de staging ont été reproduites avant
correction. Les preuves portables ne qualifient pas les surfaces système natives.

Les nouveaux jobs CI vérifient les résultats complets des tests hébergés macOS,
iOS et des tests Debug Vault. La première CI a compilé l’app macOS Release et
terminé 42 XCTest + 115 fonctions Swift Testing Vault, avec 20 arguments annoncés
par le runtime. L’OCR scanné y passe en 7,230 s sous macOS 26.6.2 / Xcode 26.6.
Les validateurs passent également. Les builds des tests ont détecté une conversion
C incompatible avec ce compilateur et un retour UIKit non utilisé ; les deux
sont corrigés pour la prochaine CI. Les cas UIKit/SwiftTerm et Cockpit doivent
encore effectivement s’exécuter dans leurs hôtes respectifs.

L’OCR PDF a échoué localement sous macOS 27 bêta, malgré une sonde Vision réussie.
L’oracle épinglé concorde sur 10 000 programmes ; la reprise après crash Debug
passe pour écriture et migration. Le corpus réel compte maintenant 65 documents
Throttle et son hash diffère du jeu figé : benchmark refusé, sans changer son
résultat attendu. Le script Vault complet (corpus, autres gates, Release), les
parcours matériels et Mac→Linux→Mac, le pilote de dix tâches mesurées sur deux
projets et le nouvel artefact signé/notarifié restent des gates séparés.

**Ce candidat est une qualification en cours, pas un accord de publication.**
