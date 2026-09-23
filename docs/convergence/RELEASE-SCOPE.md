# Première release progressive — périmètre approuvé

Décision utilisateur du 20 septembre 2026 : **cockpit fiabilisé, capacités d'autonomie non qualifiées clairement limitées**. La qualification complète de l'Autonomous Software Product Lab n'est pas un prérequis de cette première release; elle demeure une roadmap séparée, pas une promesse actuelle.

## Inclus

- Navigation et suivi existants du cockpit, TaskSpend, inventaire Claude et StatsDataService réutilisés.
- Assistant de lecture du projet : racine et budget d'outils imposés par le contrôleur, opérations shell génériques refusées.
- Choix explicite de destination : Apple/MLX sur appareil, serveur configuré distinct, Claude choisi; pas de fallback réseau implicite.
- Arrêt de consommation d'une réponse, erreurs/incomplétude visibles, refus des outils sur flux API incomplet.
- Miroir compagnon en lecture seule par défaut; contrôle du terminal séparé et révocable.
- Intention durable de vérification, pipe d'admission et diagnostic UNKNOWN; Git cible la révision vérifiée. Diff indisponible explicite et réessayable.

## Limites imposées et annoncées

- Commandes de projets **de confiance uniquement** : elles disposent des accès fichiers/réseau du compte macOS. Le cockpit le dit avant intégration. Les grants ne sont pas présentés comme une sandbox OS.
- Vérification inconnue : relance bloquée, état visible et identité copiable. Pas de reset, retry automatique ou reconnaissance d'arrêt à partir du TTL/PID seul.
- Validation de commande, satisfaction du besoin, merge, éligibilité release et publication restent distincts. Le cockpit affiche le niveau commande des reçus.
- La fusion vise un objet Git immuable; concurrence externe et crash après merge avant journal exigent encore inspection/réconciliation. Ne pas annoncer «exactly once» ou récupération automatique intégrale.
- Arrêter une réponse ne rétracte pas les données déjà transmises ni ne certifie l'arrêt/la facturation du fournisseur distant. Les octets déjà dans une queue réseau avant révocation ne peuvent être rappelés.
- Aucun Jev, Decision Engine supplémentaire, migration Super-Orchestrateur/SuperGateway, agent d'écriture non confinée nouveau ou déploiement n'est activé par cette tranche.

## Gates de cette release

Le choix progressif ne dispense pas de compiler le candidat exact, exécuter ses tests locaux, qualifier UI/AX FR/EN et les transitions introduites, ni de vérifier une archive signée, le helper, iCloud et la distribution dans leur phase autorisée. Aucun binaire n'est installé/lancé par les tests du noyau; `build-for-testing` n'exécute pas la suite native.

[Verdict courant](../../audit-output/pre-submission-verdict.md) · [preuves](PROGRESS.md) · [roadmap restante](REMAINING-GATES.md).

## Brouillon de note de release — non publié

Le cockpit distingue plus clairement les preuves disponibles, les erreurs de lecture et les opérations encore sans résultat. L'assistant conserve les demandes locales sur le Mac; un serveur ou un fournisseur externe doit être choisi explicitement. Le miroir iPhone reste en lecture seule tant que le contrôle du terminal n'est pas autorisé séparément. Les réponses interrompues n'autorisent pas d'outils et le bouton d'arrêt interrompt leur consommation.

Cette version aide à superviser des projets de confiance. Elle ne confine pas les commandes des projets et ne garantit pas une récupération automatique de tous leurs effets après incident. Les vérifications sans résultat restent bloquées pour inspection.
