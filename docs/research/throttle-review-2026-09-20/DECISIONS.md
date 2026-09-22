# Registre des décisions proposées

[Revue principale](../THROTTLE_RESEARCH_ARCHITECTURE_REVIEW.md) · [Sources et claims](SOURCES_AND_CLAIMS.md) · [Roadmap et expériences](ROADMAP_AND_EXPERIMENTS.md)

**Propositions de revue, pas autorisations d'implémentation.** B = workspace `32988f4` ; C = cockpit `1ac0a32` avec changements locaux préexistants. Les chemins ci-dessous sont observés dans C sauf mention B. Les constats F sont décrits dans la revue principale. Les obligations existantes sont à réutiliser, pas à dupliquer.

Les coûts sont des **estimations de planification**, non des mesures : S = quelques jours d'un ingénieur, M = une à deux semaines, L = plusieurs semaines. Ils supposent un périmètre borné, un checkout choisi et les interfaces actuelles conservées ; confiance faible à moyenne. Maintenance faible = tests d'invariants, moyenne = matrices de versions/plateformes, forte = exploitation d'un service supplémentaire. Aucun budget financier n'est engagé.

## D01 — conserver le cœur natif et le journal existant

**KEEP · P1.** Problème : la branche B ne contient pas tout ce que C implémente ; réinventer l'orchestration ajouterait une deuxième autorité. Preuves : `PlanStore.swift:18`, `PlanProjection.swift`, `PlanModels.swift`, F01 ; CL01/11/25, S18/19/21. Alternative simple retenue : états Swift + journal local ; pas de migration immédiate PostgreSQL/Temporal.

Bénéfice : continuité des tâches et réutilisation. Incertitude : débit/reprise à grande échelle non mesurés. Construction S pour qualification, maintenance faible à moyenne ; coût runtime local d'I/O, aucune inférence. Risque : transformer le journal en framework général. Dépendances : choix de la branche de continuation ; D08 pour nouveaux effets.

Acceptation : rejeu déterministe des fixtures, corruption visible, mutations concurrentes sérialisées, absence de régression de lecture des anciens événements. Abandon de cette solution seulement si un workload représentatif dépasse des SLO fixés et si une alternative apporte un gain mesuré. Migration : aucune maintenant ; future projection SQLite reconstruisible si besoin d'agrégation. Retour : conserver journal et lecteur précédent, aucune double écriture faisant autorité.

## D02 — une seule frontière pour les outils de lecture

**MODIFY · P0 · première implémentation proposée.** F02/F03 ; `BashSandbox.swift:53,117,169`, `AssistantTools.swift:125,134`, `ProjectKnowledgeExplorer.swift:112`. CL09/18/28, S17/S20. La liste de binaires autorisés ne contraint pas leurs opérations ; la lecture directe suit une autre politique. Réutiliser `ProjectKnowledgeExplorer` pour lecture/liste/recherche sur racine explicitement accordée ; pour Git, seules opérations à grammaire fermée. Retirer l'exécution générique si aucun besoin légitime ne la justifie.

Alternative : rallonger la denylist. Rejetée car les flags, récursions, liens et nouvelles commandes recréent des contournements. Bénéfice : réduit réellement les chemins d'accès. Construction S–M, maintenance moyenne (nouvelle opération = revue explicite), coût runtime borné, pas de modèle. Risque : refuser un ancien usage de lecture hors projet ; le message doit permettre une extension de scope explicite, pas réouvrir HOME. Dépendance : contrat de racine de l'assistant à raccorder.

Acceptation/abandon : tests de refus sans spawn, fixtures fichiers synthétiques, refus des mutations Git et actions find, secrets factices/liens/racines voisines, lectures UTF-8/Unicode légitimes ; aucun accès réel aux secrets. Abandonner une syntaxe non démontrablement contrôlable au profit de la fonction native. Migration : maintenir les noms d'outils si possible, changer la sémantique unsafe en refus explicite. Rollback : lecture native minimale seulement ; ne pas restaurer un chemin permissif.

## D03 — rendre les builds délégués bornés et traçables

**MODIFY · P0.** F04 ; `CapabilityHostService.swift:40,128,164,179,216`. CL19/28, S17/18. Un nom build n'empêche ni scripts de projet ni accès aux credentials ; l'acquittement perdu peut laisser une requête répétable. Relier chaque requête à repo réel/révision/commande autorisée, intent durable, réservation machine et observation finale. Réutiliser les primitives de collecte/timeout du vérificateur après qualification, sans présenter le groupe de processus comme sandbox.

Alternative immédiate : service délégué désactivé et build manuel autorisé. Elle reste valable tant que le chemin n'est pas qualifié. Bénéfice : pas de build fantôme, doublon ou tampon mémoire illimité. Construction M, maintenance moyenne ; latence de file assumée, I/O bornées. Risques : interruption de compilation et mauvais ciblage PID ; toute annulation vise uniquement l'exécution possédée. Dépendances D02/D04/D08 ; respect de l'exclusivité Xcode.

Acceptation : faux serveur local, refus lien/commit modifié, timeout/process descendants, sortie volumineuse, panne d'acquittement après succès, restart puis reconciliation sans relancer. Abandon : si containment macOS ne tient pas, rester manuel ou utiliser un runner isolé déjà qualifié. Migration : requêtes legacy non promues automatiquement. Rollback : désactiver l'admission, préserver les intents et réconcilier les effets en vol.

## D04 — étendre les grants existants jusqu'aux frontières d'action

**IMPLEMENT_FOUNDATION_NOW · P0.** F05 ; `PlanMCPAuthority.swift`, `PlanMCPTaskRouter.swift:58`, `TaskLauncherAuthority.swift`, `WorkflowExternalActionAuthorization`. CL09/18/22. Les grants MCP actuels sont utiles, limités à cette surface et contournables par processus du même utilisateur ; le mode legacy accepte l'absence de descriptor.

Solution : un émetteur de grants dans la couche de confiance, contrôle juste avant l'effet, liaison à tâche/mission/opération/cible/état/politique/expiration/révocation ; adaptateurs déclarent `exact`, `betweenRequests`, `unavailable` selon preuve. Pas trois nouveaux services. Pour worker hostile, stockage d'autorité/évaluateur hors son périmètre d'écriture et sandbox effectif ; une signature dont la clé est accessible au worker ne résout rien. Poser d'abord ce sous-ensemble d'admission, avant le raccord du runner D03.

Alternative : renforcer le prompt uniquement, insuffisant. Coût M–L selon isolation retenue, maintenance moyenne/forte par runtime ; vérification locale par appel, pas jugement LM nécessaire. Risque : faux sentiment de sécurité ou incompatibilité legacy. Prérequis D02 ; D03 est un consommateur à qualifier ensuite, pas une dépendance préalable. Usage concret : build délégué et mutation MCP.

Acceptation : mauvais scope/identité, grant absent/expiré/révoqué, état changé et délégation élargie refusés avant effet ; preuve de couverture par adaptateur. Abandon : surface non contrôlable reste supervisée/indisponible. Migration : mode strict pour nouvelles missions gérées ; legacy affiché comme tel. Rollback : suspendre admissions, révoquer, garder lecture et réconciliation.

## D05 — compléter l'identité et l'acquisition des preuves

**MODIFY · P0.** F06/F07 ; `WorkflowEvidenceReceipt.swift:46`, `TaskIntegrationServiceVerify.swift:49,105`, `TaskIntegrationService.swift:224`. CL04/12/13 ; S13/23/35. Réutiliser receipts/contracts ; capturer avant exécution le sujet exact, entrées matérielles suivies/non suivies nécessaires, dépendances, commande et version de politique ; artefacts par run et lecteur de résultat contrôlé. Revalider au merge l'objet exact, pas seulement un nom de branche.

Alternative : tout hasher dans HOME, rejetée pour confidentialité/coût ; ou deux SHA seuls, insuffisant. Bénéfice : pas de preuve recyclée par mtime/nom. Construction M, maintenance moyenne ; coût hash proportionnel au dossier pertinent, pas scan illimité. Risques : includes trop larges, preuves invalidées trop souvent. Dépendances D04 et D08.

Acceptation : modifier contenu d'un fichier non suivi à nom stable, substituer xcresult, changer requirements/lockfile/politique, avancer branche entre assessment et merge doit invalider. Contrat de tests obligatoire : zéro sortie n'est pas inventaire complet. Abandon : retirer un champ sans consommateur d'invalidation défini. Migration : nouveau schéma lu explicitement ; ancien receipt demeure preuve historique de niveau limité. Rollback : lecteur compatible, désactivation de promotion, pas réécriture des anciennes preuves.

## D06 — vérificateur indépendant et challenger proportionné

**MODIFY · P1.** F08 ; `WorkflowReviewGate.swift:57`, `PlanProjection.swift:90`, `RedTeamCampaignStore.swift`. CL02/06/07, S12/16. Séparer identité d'exécution, contrôle du contexte, outils, oracle, prompt, modèle et fournisseur. Supprimer l'assimilation « runtime différent = indépendance » après ajout de critères réels, sans affaiblir la barrière actuelle à l'aveugle.

Solution simple : dossier immuable, première lecture sans autosatisfaction du worker, obligations protégées et rapport de findings. Challenger déclenché sur frontière sécurité, changement d'oracle, contradiction, effet important ou échantillon préenregistré ; pas cinq agents constants. Bénéfice : réfutations utiles. Coût M, maintenance moyenne pour rubriques/datasets ; au plus un reviewer puis un challenger borné initialement. Risque : avis négatifs gratuits, corrélation et retries en boucle. Prérequis D05, critères minimaux D07, instrumentation initiale D17 et protection D18 ; qualification avant généralisation dans E2.

Acceptation : finding avec sujet/invariant/preuve/repro ou justification statique, gravité et revalidation ; faux label human refusé par canal d'acquisition ; défauts semés tenus à part détectés. Abandon : reviewer sans gain conditionnel par rapport à tests + revue simple, ou coût excessif. Migration : enrichissement du rapport, anciens rapports non promus. Rollback : conserver gate strict et revue humaine ciblée pour les risques non couverts.

## D07 — une DoD par obligations, sans probabilité globale

**MERGE_OR_SIMPLIFY · P1.** F06/F08 ; `WorkflowWorkContract`, `WorkflowVerificationContract`, `WorkflowReviewRubric`, `WorkflowDesignContract`. CL15–17/27. Ces contrats couvrent déjà le besoin ; les assembler sans nouvel objet « probabilistic DoD » concurrent.

PASS/FAIL/UNKNOWN/NOT_APPLICABLE par dimension applicable ; NA autorisé par critère avec justification validée, pas discrétion du worker. Séparer candidate, accepté, intégrable, éligible release et publié observé. Alternative : score moyen ou LLM final, rejetée. Coût S–M, maintenance moyenne des recettes ; exécution proportionnée à la tâche. Risque : bureaucratie de dizaines de champs vides. Prérequis D05 pour promotion sur preuve renforcée ; définir d'abord les critères existants. D06 et D13 consomment ces critères et sont qualifiés ensuite, sans bloquer leur définition.

Acceptation : un FAIL/UNKNOWN obligatoire bloque même si autres PASS ; données manquantes déclenchent collecte autorisée, pas systématiquement humain ; tâche documentaire ne requiert pas build gratuit. Abandon : critère sans proposition testable ni usage décisionnel. Migration : recettes par type de changement et legacy explicite. Rollback : contrats précédents toujours lisibles, critères nouveaux désactivables par version approuvée.

## D08 — récupération des effets et intégration atomique à l'échelle utile

**IMPLEMENT_FOUNDATION_NOW · P0.** F04/F07 ; `PlanStore`, `WorkflowReleaseLedgerStore.unresolvedEffects`, `TaskIntegrationService.integrate`. CL19/20/25/26 ; S18/21. Étendre le pattern intent→started→observed aux builds gérés et à Git, avec identifiant d'intention stable, fencing de réservation et état `outcome_unknown`.

Avant retry : déterminer ce que le destinataire a réalisé. Si interrogation impossible et effet non idempotent, bloquer le retry automatique. Git avancé mais event absent : comparer ancien/nouveau SHA attendu, enregistrer réconciliation ; ne pas refaire merge à l'aveugle. Alternative : simple retry sur exception, dangereuse. Coût M, maintenance moyenne par famille d'effet ; synchronisations locales et lecture distante éventuelle. Risque : prétendre transaction globale ou exactly-once. Prérequis D01 et admission minimale D04. Premier usage build avec D03 en S2 ; le raccord Git est qualifié avec D05 en S3, sans dépendance circulaire entre deux moteurs.

Acceptation : crash avant/après chaque frontière, ACK perdu, disque plein, réservation expirée avec vieux worker encore vivant, annulation, restart après plusieurs jours ; aucune action supplémentaire non autorisée. Abandon : workflow générique sans second usage réel ; garder deux adaptateurs concrets. Migration : événements additionnels versionnés, anciennes tâches sans état d'effet restent inconnues. Rollback : arrêt des nouveaux départs et réconciliation seule, journaux intacts.

## D09 — simplifier le routage autour de l'existant

**MERGE_OR_SIMPLIFY · P1.** F09 ; `MissionRuntimeService`, `DispatchAdvisor`, `DispatchBudget`, `AIProviderRegistry`, `LocalWorkerRouter`, `LocalDelegationService`. CL08/10/24 ; S27/28/30/37. Responsabilités : runtime de session, conseil dispatch, backend d'inférence, validation de résultat. Ne pas fusionner leur état aveuglément, partager les faits de capacité/disponibilité/confidentialité et les raisons de refus.

Alternative : service Decision Engine, inutile maintenant. Corriger l'explication « every runtime is out of window » lorsque la liste est vide faute de mesure ; ne pas traiter noms de skills comme preuve de capacité exécutée. Bénéfice : choix explicable et portable. Coût S–M, maintenance moyenne des adaptateurs ; règles locales, fallback borné. Risque : fuite vers backend moins privé lors d'une panne. Dépendances D04/D12/D17.

Acceptation : unavailable ≠ incapable ≠ budget inconnu, route admissible avant classement, aucune baisse de confidentialité, aucun provider indispensable sauf contrat explicite. Abandon : heuristique sans observable ou bénéfice. Migration : conserver mode advisory et préférences ; pas d'auto-routing implicite. Rollback : choix explicite du runtime et backend autorisé.

## D10 — Jev en observation sur diagnostics seulement

**EXPERIMENT · P3.** CL21–24, S01–11 ; réutiliser `XcodeBuildErrorsService`/`TestOutcomeDetector` pour l'entrée, le contrat de résultat de délégation si adapté. Problème non démontré : coût/qualité du triage ambigu. Aucun Jev existant confirmé dans les sources maintenues inspectées.

Expérience E3 : règles vs modèle local vs LLM structuré vs Jev, même dossier, aucune commande exécutée par la recommandation. OTHER et états insuffisant/contradictoire/hors périmètre explicites ; UNAVAILABLE/INVALID_OUTPUT produits par adaptateur, jamais transformés en oui. Conserver distributions natives et version exacte, pas score normalisé inter-fournisseur.

Alternative : règles seules, baseline obligatoire. Construction S pour protocole, M si futur adaptateur nécessaire ; maintenance moyenne si adopté. Coût des appels et préparation plafonné lors d'une autorisation séparée ; pas d'engagement maintenant. Risque : faux positif rassurant, quota, données sensibles. Dépendances D05/D17 et accès/données autorisés.

Acceptation/abandon : critères E3 préenregistrés, gain sur tâches tenues à part sans hausse des erreurs graves ; abandon si oracle faible, volume insuffisant, calibration instable ou gain aval nul. Migration/rollback : shadow indépendant des actions ; retirer candidat sans migration du produit.

## D11 — conserver le Vault, séparer mémoire et autorité

**KEEP · P1**, avec raccords **MODIFY** bornés à D05. `ResearchReceipt`, `VaultAuthorization`, `ResearchVaultGateway`, `EncryptedObjectStore`, SQLCipher/FTS/ResearchLogic ; CL11–14/26/29, S21/22/33, ADR0002. Dossiers de décision référencent des preuves autorisées ; la mémoire retrouvée n'accorde aucun droit et un résumé ne remplace pas l'original.

Alternative simple : lookup structuré pour identités/états, recherche exacte pour code, FTS pour documents ; embeddings uniquement si gain mesuré. Pas de seconde base graphe, pas de Letta imposé. Bénéfice : réemploi des sources/générations/contradictions. Construction S–M raccords, maintenance moyenne ; coût borné de retrieval. Risque : copier secrets et fausse permanence d'un fait approuvé. Dépendances D05 et règles de rétention à décider pour nouveau type de donnée.

Acceptation : scopes projet/sensibilité, retrait et génération invalidant la vue, source absente visible, suppression propagée aux caches selon protocole ; reconstruction à partir d'artefacts vérifiable. Abandon : nouvelle indexation sans benchmark ou duplication d'autorité. Migration : références entre journaux et Vault, pas déplacement forcé. Rollback : projection reconstruite et retrieval textuel existant ; ne pas restaurer un contenu supprimé.

## D12 — prolonger admission et coûts réels, sans faux plafond fournisseur

**MODIFY · P1.** `BudgetAdmissionStore`, `TaskBudgetAdmission`, `TaskSpend`, `StatsDataService`, `ClaudeAgentInventory`, `BackendCapabilityProfile`. CL10 ; S27. Réserves vérification/release déjà codées, expiration conservatrice et settlement upper-bound existants. Ajouter couverture des exécutions réellement possédées, réconciliation des inconnus et réservation machine pour build/inférence/test.

Alternative : inventer un Credit Scheduler ou calculer solde=0 si inconnu, rejetée. Coût M, maintenance moyenne ; métriques locales et faible coût de réservation. Risque : double comptage des transcriptions, réserver moins que consommé, starvation ; pas de promesse de tuer un modèle au token exact si SDK ne le permet pas. Dépendances D08/D09/D17.

Acceptation : tous essais/annulations comptés, unknown ≠ zéro, réserve protégée, overflow signalé, un seul xcodebuild géré, jobs externes signalés sans les tuer. Abandon : estimation trompeuse ou collecte trop intrusive. Migration : conserver unités et fidélité, champs additionnels seulement. Rollback : admission conservative et choix manuel, aucune réduction de sécurité pour économiser.

## D13 — rendre la supervision fidèle à l'état observé

**MODIFY · P1**, avec **KEEP** des libellés d'intégration actuels. `PlanFlow.swift:21`, `FlowWording.swift:14,33`, catalogue EN/FR, `WorkflowDesignContract`, `TaskSpend`. F10 ; CL27, S26. La présentation affiche déjà Integrated/Intégré : le contre-audit retire le renommage UI initialement envisagé. Qualifier les états de supervision et raccorder uniquement les observations nouvelles de D05/D08 : preuve manquante, budget inconnu, effet non réconcilié, fraîcheur et portée de l'approbation. Vérifier le parcours existant avant de prescrire une nouvelle vue.

Alternative : nouveau dashboard « confidence », rejetée. Construction S–M, maintenance faible ; pas de modèle par rafraîchissement. Risque : encombrement ; priorité aux exceptions et à l'action utile. Dépendances D07/D08 ; réutiliser inventory/stats et annulation du polling.

Acceptation : parcours clavier/VoiceOver, focus après refus, EN/FR, ready/empty/error/loading, absence de passage intégré→publié sans reçu ; coût estimé visiblement distinct. Tests visuels déterministes puis utilisabilité sur tâches définies. Abandon : champ technique sans décision utilisateur ou besoin déjà satisfait par la vue existante. Migration : projections compatibles, libellés actuels conservés. Rollback : vue précédente et mécanismes de blocage inchangés.

## D14 — intégrer le cycle produit par tranches, pas par agents métiers

**IMPLEMENT_FOUNDATION_NOW · P1.** `WorkflowProductCycleContract`, `WorkflowReleaseManifest`, `WorkflowReleaseLedgerStore`, `WorkflowPlatformModels`, `ProductSignals`, Updater/CrashReporter. CL19/20/27, S23/36. Un contrat relie besoin, track plateforme, preuve, candidat release et suivi. Ces modèles déclaratifs ne sont pas des connecteurs de publication exécutés.

Alternative : manuels/checklists liés au contrat pour premier canal ; retenue jusqu'à qualification d'un effecteur. Usage immédiat : distinguer readiness et action autorisée, puis observer un incident/feedback qui rouvre une exigence. Coût M pour un canal, maintenance moyenne ; aucun worker marketing permanent, dépenses externes séparées. Risques : schémas décoratifs et automatisation des communications. Dépendances D05/D07/D08/D13/D15.

Acceptation : manifeste gelé, source/artifact/target cohérents, gate inconnu bloque, publication requiert autorisation fraîche, résultat externe observé ; incident lié à release et mitigation spécifique. Abandon : connecteur sans cas utilisateur ou accès autorisé. Migration : étendre un canal, garder le manuel. Rollback : stopper publication nouvelle, préserver state et compenser selon canal, jamais supposer undo universel.

## D15 — réutilisation et dépendances par preuves

**MODIFY · P1.** `WorkflowDependencyModels`, `WorkflowTechnologyReuseModels`, `WorkflowIPModels`, locks/notices. CL32, S23. ADOPT/ADAPT/WRAP/FORK/BUILD existent ; garder gates obligatoires, rendre visibles sources, versions, couverture et dates. Les poids et seuils de scores restent des heuristiques explicables.

Alternative : inventaire léger + décision documentée plutôt qu'un moteur de découverte autonome. Coût S–M pour un composant réel, maintenance moyenne pour mises à jour ; analyse offline avant appel modèle. Risques : SBOM incomplet, transitive/build plugins, confusion interne/open-source. Dépendance : H2 pour licence publique, pas pour poursuivre l'inspection.

Acceptation : comparaison fonctionnelle, licence/provenance/supply-chain/maintenance, coût de fork et sortie ; aucune adoption avec gate impératif inconnu. Abandon : composant sans propriétaire ni besoin ou réécriture sans avantage démontré. Migration : enrichir évaluation existante, aucune dépendance changée dans cette phase. Rollback : précédente version verrouillée et preuve de compatibilité, sous réserve de sécurité.

## D16 — plateformes intentionnelles, macOS27 non imposé

**DEFER · P2** pour relèvement global de cible et expansion ; **KEEP** cible actuelle en attendant. `project.yml`, `WorkflowPlatformModels`, `WorkflowPlatform`, SDK local ; CL31, S24–27. Hôte : macOS14 déclaré ; fonctionnalités modernes gardées par disponibilité. Produits : Apple/Android selon besoin. Remote Linux optionnel pour travail portable ; il ne compile pas automatiquement les produits Apple.

Alternative : availability checks et fallback, plus simple qu'exclure tous les anciens OS. Coût S d'inventaire, M–L par nouvelle plateforme, maintenance forte pour parité réelle ; GPU/modèles/build partagent les ressources. Dépendance H3 et D12.

Acceptation : preuve API locale + disponibilité live + tests des versions supportées/appareils, matrice de capacité/perte justifiée ; SDK installé ne prouve pas entitlement/signature. Abandon : plateforme sans utilisateur ou sans quota de maintenance. Migration : par track/version, aucune modification maintenant. Rollback : fallback ancien backend/ancien OS sans fuite de données.

## D17 — baseline avant intelligence adaptative

**IMPLEMENT_FOUNDATION_NOW · P1.** `docs/testing/workflow.md`, `pilot-10-tasks.csv`, receipts et coûts. CL05/08/10/23 ; S12–14/37. Usage immédiat : décider si D06/D09/D10 améliorent réellement le résultat. Étendre le pilote préparé ; aucune donnée de tâche inventée.

Alternative : lire les scores publics, insuffisant. Coût S de cadrage puis M de collecte/annotation, maintenance moyenne ; contrôle strict du budget d'évaluation. Risque : sélection de succès, contamination, labels bruités. Le cadrage et l'inventaire commencent en S0 avec mesures inconnues explicites ; D05/D12 améliorent ensuite couverture et acquisition. E1–E4 les qualifient, sans exiger toutes les mesures finales pour commencer la baseline.

Acceptation : toutes tentatives/cancellations, dénominateurs et inconnus, données réglage/test séparées par projet et temps, défauts semés protégés, incertitudes publiées. Abandon : métrique sans relation à besoin ni oracle fiable. Migration : CSV initial compatible puis projection structurée si requêtes nécessaires. Rollback : instrumentation versionnée ; garder observations brutes minimisées, aucun apprentissage en ligne actif.

## D18 — protéger l'auto-modification

**IMPLEMENT_FOUNDATION_NOW · P0.** F05/F08 ; contrats/gates/instructions/recettes et code de lancement. CL30, S17/23/29. Usage : Throttle peut être son propre projet ; worker ne doit pas modifier les règles qui valident sa tâche.

Solution minimale : candidat N+1 construit séparément, évalué par contrôleur/policy/oracles N en lecture seule hors scope worker ; modification d'oracle examinée séparément, corpus tenu à part, promotion autorisée et versionnée. Pas d'agent constitutionnel nouveau. Coût M, maintenance moyenne ; double exécution ciblée seulement pour changement de contrôleur. Risque : vieux contrôleur lui-même déficient ; contre-audit indépendant de frontière nécessaire. Prérequis : frontière d'autorité minimale D04 ; cette protection accompagne D05. D17 mesure ensuite sa robustesse, sans conditionner la protection initiale à un dataset déjà complet.

Acceptation : tentative de modifier rubric, test bloquant, politique ou clé d'autorité ne change pas la décision de N ; aucun auto-relaunch/auto-publish. Abandon : auto-promotion sans isolation démontrable. Migration : voie spéciale pour composants de confiance. Rollback : conserver N exécutable et compatible avec journaux, puis requalifier avant retour.

## D20 — supprimer les couches sans bénéfice prouvé

**REJECT** maintenant : Decision Engine autonome, probabilité globale de completion, graphe DB dédié, dix-neuf agents/services permanents, score qui annule une interdiction, publication automatique par simple confidence. **DEFER** Temporal/LangGraph comme autorité globale, bandit/RL, classifieur d'outcome, mémoire auto-évolutive et distribution multi-host obligatoire. CL01/06/08/11/16/22/24/25 ; S18/19/32–34/37.

Alternative retenue : D01–18, une responsabilité ajoutée seulement pour un défaut observé. Coût de construction évité non chiffré ; chaque couche rejetée aurait coût d'exploitation et de contexte. Risque du minimalisme : surcharger l'app et rater un besoin multi-host futur. Dépendances pour réouverture : résultat E1/E4, vraie demande distante et SLO que l'existant ne tient pas.

Acceptation : aucun service abstrait sans usage, propriétaire, métrique et critère de retrait. Abandon de ce verdict seulement avec expérience comparative et coût de migration/maintenance explicite. Migration/rollback : aucune adoption réalisée ; spike isolé et supprimable s'il est ultérieurement autorisé. Une nouvelle source marketing ne suffit pas à rouvrir la décision.

## Arbitrages humains authentiques

| ID | Décision hors autorité | Recommandation de revue et conséquence de l'absence de décision |
|---|---|---|
| H1 | Branche d'implémentation et périmètre de la première tranche | Repartir de C ou d'une intégration explicitement choisie, jamais recopier toutes ses capacités dans B. La revue peut finir ; aucune fusion ni implémentation ici. |
| H2 | Propriété/licence et périmètre public par composant | Notices MIT constatées et historique commercial à réconcilier par propriétaire compétent. Ce n'est pas une conclusion juridique de violation ; aucune publication/relicence décidée. |
| H3 | Versions minimales, clientèle et priorité Android/visionOS | Conserver cibles déclarées ; décider sur utilisateurs et coût de support, pas seulement SDK27 installé. |
| H4 | Données/accès/budget d'une expérience externe, délégation durable des actions | E3 reste conçu mais non lancé. Permissions permanentes, publication et coûts futurs exigent un contrat borné ; la revue ne l'accorde pas. |

L'absence de mesures runtime n'est pas automatiquement un arbitrage humain : elle appelle d'abord le protocole adapté et son autorisation d'exécution, pas une opinion produit.
