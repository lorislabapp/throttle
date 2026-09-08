# Workflow de validation commun aux projets

Ce protocole s’applique aux tâches menées avec Throttle. Il complète les commandes propres à chaque dépôt. Il ne remplace ni les règles locales, ni les validations d’appareil, ni les autorisations de publication. Version initiale : 2026-09-08.

## Pour chaque changement

1. **Fixer le résultat attendu.** Écrire le comportement observable, les cas limites et la commande de vérification avant de modifier le code. Pour un bug, obtenir une régression qui échoue sur l’ancien comportement. Pour une petite correction visuelle ou documentaire, une inspection ciblée suffit.
2. **Préparer le contexte utile.** Vérifier dépôt, branche, modifications présentes, spécification et décisions applicables. Donner les références et extraits nécessaires ; séparer les sources externes des instructions. Un original absent, périmé ou corrompu reste indisponible. Conserver une référence vérifiable aux détails omis.
3. **Corriger puis vérifier.** Exécuter les tests comportementaux ciblés. Élargir aux frontières affectées : vrai stockage, vrai dépôt Git, protocole, processus ou rendu. Une compilation seule ne valide pas le comportement.
4. **Tester un échec plausible.** Selon le changement : interruption, ordre inversé, écriture impossible, données corrompues, réponse incomplète, délai dépassé, accès refusé. Les graines et entrées doivent permettre de rejouer le défaut. Une simulation de pannes n’est pas une preuve formelle exhaustive.
5. **Conserver la preuve.** Commande, snapshot des sources, version des outils, résultat final, tests réellement terminés, échecs et omissions. Une sortie de terminal verte reste une observation ; l’acceptation demande le résultat complet du bon ensemble de tests. Relancer après modification des sources concernées.
6. **Relire les risques et le résultat.** Vérifier l’architecture, les invariants, les modifications des tests et les cas non couverts. Une revue par un autre modèle apporte un avis supplémentaire ; elle ne remplace pas l’oracle comportemental. Une modification d’un test ne doit pas masquer la régression.

## Choisir le niveau de test

| Frontière modifiée | Vérification utile |
|---|---|
| Calcul, parser, machine à états | Cas limites et invariants ; propriétés/métamorphismes si les transformations ont un sens |
| Stockage, transaction | Vrai moteur temporaire, rollback, corruption, reprise après interruption |
| Git / orchestration | Vrai dépôt temporaire, conflits, SHA périmé, arrêt du processus, résultat de vérification lié au snapshot |
| Réseau / IPC | Contrats, protocole réel local, authentification, délais et refus ; pas de test d’un service de production par défaut |
| Contexte / recherche | Préservation des erreurs, budget réel du paquet, hashes, isolation projet, sources périmées, abstention ; requêtes humaines distinctes des titres des documents |
| UI Apple | Tests de logique plus parcours visuel/accessibilité pertinent ; tests du produit hébergé séparés des packages sans interface |
| Sécurité | Analyse statique et dépendances, contrôles négatifs, frontières d’accès ; tests offensifs uniquement sur la cible autorisée |

Les mocks contrôlent des conditions difficiles à provoquer. Au moins un test à la frontière réelle reste nécessaire lorsque le contrat externe est précisément le risque. Pas de simulation distribuée générale ajoutée à un composant qui n’est pas distribué.

## Commandes disponibles dans Throttle

```sh
python3 -B -m unittest discover -s scripts/tests -p 'test_*.py' -v
python3 scripts/verify-core-evidence.py --output-parent /private/tmp/throttle-core-evidence
npm --prefix experiments/local-context-refinery test
npm --prefix experiments/local-context-refinery run eval
npm --prefix edge-agent test
```

La suite Swift isolée copie les sources et tests de production sans les transformer. Elle vérifie séparément XCTest et Swift Testing, refuse les rapports absents, les cas attendus non terminés et les sources modifiées pendant le test. Elle conserve reçus, hashes et rapports XML. Son périmètre est **le sous-ensemble des validateurs et du contexte**, pas l’app complète.

Les suites `ThrottleShared`, les tests macOS/iOS et le script complet `Packages/ResearchVaultKit/Scripts/verify.sh` restent nécessaires selon le changement. Ce dernier dépend notamment d’un corpus DeepSearsh et d’un oracle externe précis : l’absence de ces entrées doit rester visible. Un passage partiel ne devient pas un passage complet.

## Pilote sur dix tâches réelles

**État : une tâche réelle documentée, 0/10 observations complètement mesurées.** L’intégration sur `3abf6a6` passe ses validations locales, mais son coût total et le temps humain n’ont pas été relevés : sa ligne reste incomplète et ne démontre aucun gain. Les régressions synthétiques ne comptent pas comme des tâches. Utiliser [le registre](pilot-10-tasks.csv), compléter les mesures dès le début des prochaines tâches éligibles, sans choisir seulement les succès.

Choisir des tâches réparties entre correction, fonctionnalité, intégration et reprise d’une session. Fixer pour chacune le critère d’acceptation avant de commencer. Enregistrer les modèles et versions, coût de toutes les tentatives et revues, temps humain actif, délai total, relectures et régressions constatées après acceptation.

Comparer les variantes sur des tâches comparables ou des réexécutions isolées du même snapshot, en alternant l’ordre pour limiter l’apprentissage. Conserver les échecs, abandons, coûts inconnus et erreurs d’outillage. Distinguer variante de contexte et changement de modèle. Dix tâches servent d’abord à vérifier l’instrumentation, pas à prouver un multiplicateur universel de productivité.

Mesures prioritaires : tâches acceptées / tâches tentées ; coût total / tâches acceptées ; temps humain / tâche acceptée ; régressions ; proportion de sources requises effectivement récupérées. Le coût observé dans le terminal ne couvre pas automatiquement toute la facturation, et les résumés de suites peuvent se répéter.

Promotion d’une nouvelle politique de contexte : aucun échec critique connu masqué ; aucun mélange de projets dans les cas d’isolation ; budgets respectés ; provenance et abstention vérifiées ; gain observé sur les tâches retenues. À qualité insuffisante ou preuve manquante, conserver la politique précédente.

## Langages

Conserver Swift pour les interfaces Apple et les intégrations natives de Throttle. Évaluer Rust pour un nouveau cœur portable, des protocoles ou des composants où la mémoire et la concurrence sont des risques centraux. Mesurer aussi le coût de FFI, compilation, distribution et maintenance. Ni Rust ni son compilateur ne prouvent la logique métier ; ne pas réécrire un projet uniquement pour suivre l’exemple de la vidéo.
