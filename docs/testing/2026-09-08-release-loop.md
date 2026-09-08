# Boucle de qualification de la release 3.6.0

Base : `cdae2c718ac47bbfae19ca2f6fa17ceb077d89d7`, worktree `build/context-testing-3.6.0`, branche `feat/context-testing-3.6.0`. Canal : macOS Developer ID + Sparkle ; compatibilité des companions, aucune publication App Store. Le flux public relu au démarrage expose 3.5.2 (218) ; 3.6.0 (219) reste provisoire jusqu’au gel final.

L’utilisateur a approuvé l’implémentation du plan et confirmé deux critères : dix tâches entièrement mesurées avant release, sur au moins deux projets. Les tâches du portefeuille doivent être réellement confiées ; aucune observation ni mesure ne sera inventée. La demande des premières tâches a été envoyée pendant la qualification technique.

## Contrat de boucle

Reproduire → corriger → vérifier le comportement → contre-revoir → conserver la preuve. Rejouer les frontières affectées après modification ; ne pas effacer un échec antérieur. Une erreur d’environnement, un résultat absent ou une omission obligatoire maintient le gate ouvert. Les sorties des modèles et les compteurs de terminal ne sont pas l’oracle d’acceptation.

## État réconcilié

| Lot | État | Preuve ou condition de fermeture |
|---|---|---|
| Contexte et validateurs de `cdae2c7` | PASS historique lié aux sources | 627 macOS réussis, cinq omissions opt-in ; 39 validateurs. À rejouer après les nouvelles modifications |
| CI macOS complète | IMPLÉMENTÉ, exécution fraîche ouverte | Job indépendant, signature ad hoc, inventaire natif comparé au résultat xcresult, reçus et artefacts ; 14 tests adversariaux passent et replay 632/632 cas. Build complet/CI GitHub encore ouverts |
| Préparation Sparkle | CORRIGÉ, revue en cours | L’absence de vérificateur pouvait laisser continuer le stage. Vérification Ed25519 obligatoire avec clé publique du candidat ; 11 tests passent et une vraie archive historique est vérifiée, sans accès à la clé privée |
| Publisher iCloud macOS | CORRIGÉ, contre-revue supplémentaire | Un `accountStatus` ancien pouvait réactiver après opt-out. Générations, annulation et purge ; six tests avec backend contrôlé passent. Une régression supplémentaire vérifie la révocation synchrone à réception de `CKAccountChanged` |
| Confidentialité du companion | CORRIGÉ partiellement, contre-revue | Identité au lancement, réponses CloudKit périmées, ancienne connexion LAN/terminal et encodage tardif d’historique sont couverts. Widget avant vérification et buffer alternatif du terminal restent en correction. Build iOS/visionOS et surfaces système ouverts |
| Bornes des projets Vault et enveloppe IPC | PASS ciblé, intégration ouverte | Clés 64/65/128 acceptées et 129 refusées : neuf tests rejoués. Enveloppe JSON bornée à 65 536 octets côté client et service, requête décodée toujours à 4 096 octets, 64 projets maximum : 21 tests XPC en processus passent. XPC signé distinct |
| OCR / suite Vault complète | FAIL rouvert | `verify.sh` échoue sur `.ocrUnavailable` après 30,178 s ; test isolé échoue après 37,777 puis 75,663 s. Une sonde CPU `.accurate` réussit entre-temps en 60,795 s ; elle ne qualifie pas l’extraction PDF. Ni ce résultat ni le PASS historique à 178,420 s ne ferment le défaut |
| Oracle et autres gates Vault | OPEN | Oracle public restauré au commit/licence épinglés ; suite interrompue avant son exécution par l’échec OCR. Corpus local disponible |
| Identité / arrêt / transfert natifs | OPEN runtime | Six nouveaux tests raccordent les vrais chemins `hibernate`, `stop`, `continueMission` à des processus inertes bornés. Parse/lint passent, compilation et exécution encore ouvertes. Le lot18 ne contenait aucune conversation : transfert Mac→Linux→Mac et Quit réel non qualifiés |
| UX/AX et compatibilité | OPEN | Previews antérieures conservées ; parcours réels, clavier/VoiceOver, performances et architecture livrée à qualifier |
| Pilote | OPEN, 0/10 complètement mesurées | Registre existant ; tâches sur plusieurs projets demandées, coûts/temps inconnus conservés comme inconnus |
| Candidat signé/notarifié | OPEN | Le DMG de `3abf6a6` ne contient pas ce delta. Nouvelle archive après stabilisation, puis accord pour l’upload exact à Apple |

## Risques confirmés par contre-revue

Les trois nouveaux constats de sécurité sont distincts des anciens tests verts : stage sans signature vérifiée, réactivation de la publication après opt-out, et conservation/réintroduction du miroir d’un ancien compte. Aucun accès à un compte iCloud réel ni perte de données utilisateur n’est nécessaire pour les reproduire : backends suspendus, génération de connexion et stockage temporaire forment les oracles.

Les avertissements QoS de plan-store ne sont pas un crash démontré. Les tests `OwnedProcessTermination` couvrent cinq vrais groupes synthétiques, pas le raccordement complet du Cockpit. La fermeture d’une preview utilise un chemin de terminaison isolé et ne valide pas Quit du produit.

La contre-revue du companion a retrouvé deux lectures possibles de données anciennes : le widget lit la dernière valeur persistée avant réconciliation de l’identité ; le reset normal de SwiftTerm ne démontre pas l’effacement de son buffer alternatif. Ces constats ne sont pas couverts par les seuls mocks de transport. Les surfaces WidgetKit, ActivityKit et notifications, ainsi qu’un changement de compte lorsque l’app est absente, restent des qualifications séparées.

## Sources concurrentes et CI

Une autre session a ajouté un lot PlanStore/diagnostics dans le même worktree, documenté dans `sota-integration-ledger.md`. Ses fichiers sont préservés ; aucune validation de notre lot ne leur est attribuée. Une demande de réconciliation a été envoyée à l’utilisateur.

Le worktree `build/release-loop-ci`, branche `qualification/3.6.0-release-loop-ci`, est créé depuis `cdae2c7` pour qualifier une sélection explicite de nos correctifs. Une preuve de cette sélection ne sera pas présentée comme une preuve du worktree combiné. La CI distante prévue au plan permettra les builds frais ; localement, l’espace est revenu de 3,4 Gio à moins de 1 Gio pendant la campagne, en dessous des 10 Gio exigés avant le build macOS.

Les 37 tests Python passent. Le scan Gitleaks des deux commits locaux signale douze entrées : chacune a été vérifiée comme une empreinte SHA-256 identique au fichier source référencé, et non comme un secret. Le rapport de tri est conservé. Aucun envoi de la branche CI n’a encore été effectué à ce checkpoint.

## Sortie et artefacts

Le verdict reste **NO-GO** tant qu’un gate obligatoire ci-dessus reste ouvert. Le reçu final doit identifier la révision, les entrées et commandes, les cas terminés, les omissions, les versions d’outils et les hashes du candidat. La preuve du package, celle du produit hébergé, celle de l’app signée et celle d’un appareil restent distinctes.

Après préparation et qualification de l’artefact exact, l’upload de notarisation demandera son accord explicite conformément au skill `publish-apple`. La publication publique et ses contrôles normal/cache-bust/Sparkle/T+15 sont une phase distincte. Aucun remplacement de l’app de travail ou du service edge de production n’est implicitement nécessaire aux bancs isolés.
