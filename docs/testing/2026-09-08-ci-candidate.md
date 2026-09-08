# Candidat de qualification 3.6.0

Base : `cdae2c718ac47bbfae19ca2f6fa17ceb077d89d7`. La branche
`qualification/3.6.0-release-loop-ci` ajoute une sélection explicite de 38 fichiers
pour la confidentialité du miroir, les bornes IPC, le staging et les tests/CI.
Le lot PlanStore/diagnostics développé parallèlement n’est pas inclus dans cette
sélection. Sa qualification doit rester distincte.

Preuves locales avant CI : 71 tests Python réussis, sept tests du publisher,
26 tests portables du companion, neuf tests de clés projet et 21 tests XPC en
processus. SwiftLint 0.63.2 strict et `git diff --check` passent sur cette sélection.
Les régressions de notification iCloud et de staging ont été reproduites avant
correction. Les preuves portables ne qualifient pas les surfaces système natives.

Les nouveaux jobs CI vérifient les résultats complets des tests hébergés macOS et
des tests Debug Vault. Les cas UIKit/SwiftTerm et Cockpit doivent effectivement
s’exécuter dans les hôtes respectifs. Le résultat CI frais reste à obtenir.

L’OCR PDF a échoué localement, malgré une sonde Vision réussie ; le défaut reste
ouvert. Le script Vault complet (oracle, corpus, crash/reprise, Release), les
parcours matériels et Mac→Linux→Mac, le pilote de dix tâches mesurées sur deux
projets et le nouvel artefact signé/notarifié restent des gates séparés.

**Ce candidat est une qualification en cours, pas un accord de publication.**
