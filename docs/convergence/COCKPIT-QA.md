# Qualification du cockpit progressif — protocole candidat

**PARTIELLEMENT EXÉCUTÉ — état actualisé le 21 septembre, voir ci-dessous.** Revue source du 20 septembre 2026 : aucun nouveau blocage HIGH établi dans les flux décrits après corrections. Ce constat ne remplace pas leur observation dans le candidat. La suite native utilise l’hôte XCTest isolé existant (`AppDelegate.isIsolatedHost`, `AppDelegate+Launch`, `AppDelegate+Termination`, `ThrottleApp`) : DB mémoire, services et singleton de production non démarrés. Cette frontière a été relue avant préparation de suites natives ciblées ; le lancement de cet hôte ne remplace ni ne redémarre l’app installée. Les parcours produit complets ci-dessous restent distincts.

## Environnement à préparer

Candidat identifié par empreintes et résultat de build terminal, projet Git synthétique sans données privées, defaults isolés, fournisseurs/transport factices ou comptes de test expressément autorisés. Conserver les sessions et l’app installée. Pas de shell sur un dépôt utilisateur, de nouveau grant réel, de coût API ou de CloudKit réel pour contourner une fixture manquante.

| Parcours | Actions | Preuve attendue |
|---|---|---|
| Stop avant réponse | Fournisseur factice retardé; Envoyer puis Stop avant premier delta | Aucun outil/fallback ; aucun retour tardif ; nouvel envoi possible |
| Stop pendant réponse | Flux lent; Stop puis nouvel envoi | Ancien tour arrêté, nouveau intact ; Cmd-Entrée et VoiceOver identifient l’action |
| Changement de projet | Réponse sur A; passer sur B | A annulé localement ; aucun contexte/delta/coût de A attribué à B |
| UNKNOWN | Journal fixture avec intention sans résultat | UUID/raison visibles, intégration bloquée, aucun processus ni mutation Git |
| Diff indisponible | Diff valide puis référence fixture retirée; retry; référence restaurée | Ancien diff effacé, erreur différente du vide, retry récupère état exact |
| Contrôle compagnon | Miroir ON/control OFF, puis ON, révocation avec trame en attente | OFF refuse terminal ; ON agit seulement dans session existante ; trame tardive et taps refusés après révocation |
| Persistance des secrets | Backend factice save/read indisponible, nouveau token/migration | Ancienne valeur préservée ; erreur visible ; LAN bloqué sans identité persistée |
| FR/EN, clavier, accessibilité | Chaque écran, fenêtre étroite, VoiceOver | Textes complets, raisons audibles, focus exploitable, arrêt visiblement actif et saisie nommée |
| Upgrade/rollback | Copie synthétique ancien journal, ouverture nouveau candidat, retour à ancien lecteur | Pas d’effacement ; événements inconnus/UNKNOWN conservés et bloqués, comportement documenté |

Capturer version/build, SHA des sources et artefact, langue/macOS, étapes exactes, observation attendue/réelle et fichiers de preuve. Ne marquer PASS qu’après observation terminale. Diff/rebind et RemoteSessionsCredential ont désormais un reçu natif réussi distinct du harness. Quatre vues de dépenses sont montées et inspectées via AX en anglais ; les parcours complets de ce tableau restent NON EXÉCUTÉS.

Après qualification locale : archive et signatures/helpers/entitlements/Sparkle selon phase autorisée. Éligibilité et autorisation de publication restent distinctes.

Complément du 20 septembre : dix tests RemoteTransferJournal PASS dans le candidat Debug isolé ([reçu](evidence/native-transfer-tests/summary.json)), portant le total natif ciblé à 55. Journal tronqué, identité changée, écrivain concurrent, reprise de métadonnées sans processus et résultat de retour contrôlés sur fixtures. Cela ne ferme pas le scénario upgrade/rollback complet de cette matrice. Archive Release non signée et structure de bundle également PASS ; parcours interactifs du candidat toujours non exécutés.

## Résultats ciblés du 21 septembre

| Parcours | Observation et limite |
|---|---|
| Stop avant/période de réponse, nouveau tour, changement A→B | 3 tests de la vraie vue Assistant PASS, saisie NSTextView et actions AX ; provider/context injectés. Pas de fournisseur réel ni preuve d’arrêt de facturation. |
| UNKNOWN FR/EN | 2 tests PASS : texte/UUID visibles dans AX, bouton disabled, relance refusée et absence du marqueur de commande. |
| Diff FR/EN | 2 tests PASS : action Retry et échec réel sans worktree ; état chargé/vide injecté ensuite. Réparation réelle Git non démontrée par ces deux tests ; autres tests du modèle conservés. |
| Contrôle compagnon / secrets | 12 tests PeerTerminalBoundary PASS : tickets révoqués, contrôle OFF, attache remplacée, callbacks tardifs, pairing indisponible et migration refusée. Pas de socket TLS, téléphone ou Keychain réel. |
| Compte CloudKit / opt-out | 9 tests publisher PASS sur backend/notifications injectés ; pas de compte ni conflit multi-Mac réel. |
| Rendu, langues complètes, clavier, VoiceOver | OUVERT. Captures hors écran avec aplats blancs sans textes de boutons/bulles ; mélange linguistique Assistant observé. Les assertions AX ne prouvent pas le rendu final. |
| Upgrade/rollback complet | OUVERT ; seuls les cas ciblés du journal de transfert ont un résultat terminal. |

[Reçus et limites](PROGRESS.md#qualification-du-21-septembre--tests-ciblés-terminés), [captures](evidence/native-cockpit-20260921/ui-attachments/manifest.json). Ne pas convertir cette matrice en validation de bout en bout.

### Protocole pour lever la limite des captures

Les fixtures utilisent `NSHostingView` dans des fenêtres hors écran (-10000, -10000), puis `cacheDisplay(in:to:)`. Le rendu exporté n’est pas une capture du compositeur de fenêtre. Prochaine vérification : afficher uniquement l’hôte XCTest isolé avec les mêmes données synthétiques, relever son apparence effective, observer une fenêtre réelle et ses contrôles en anglais puis français. Conserver les sessions de l’app installée ; ne pas la redémarrer. Comparer cette observation aux captures actuelles avant toute correction de couleurs produit. Vérifier le bouton de retry, le bouton désactivé UNKNOWN, la bulle assistant et la saisie ; ensuite parcours clavier et VoiceOver. Ce protocole est NON EXÉCUTÉ.


## Observation de fenêtres réelles — 21 septembre, 07:16–07:38

Le protocole est désormais exécuté partiellement, via `HostedViewReview` opt-in dans le seul hôte XCTest. Les captures CUA de la conversation montrent correctement les textes absents des PNG `NSView.cacheDisplay`, même lorsque cette dernière capture est faite sur une fenêtre visible. Il s’agit donc d’une limite de cette capture raster ; aucune correction de couleurs produit n’est justifiée par ces PNG.

- `071949` : Assistant réel fr_FR clair, arrêt/nouveau tour visibles. Saisie synthétique puis **Cmd-Entrée** déclenche le tour, Stop l’interrompt ; focus conservé. Test terminal PASS.
- `072423` : Assistant réel en_US clair ; fenêtre réduite à environ 480×600, textes et notice d’arrêt lisibles sans troncature. Assertion AX de la notice partielle PASS. Test terminal PASS. Effacement de la conversation révèle trois suggestions encore françaises.
- Correction : clés anglaises et quatre traductions françaises explicites dans `ProjectAssistantTab.swift` / `Localizable.xcstrings`. Aucun fournisseur réel ni changement de préférences persistantes.
- `073017` : les quatre suggestions anglaises sont observées dans la vraie fenêtre ; nouveau test de langue PASS.
- `073134` : les quatre suggestions françaises sont présentes dans AX et le test PASS. La sortie de capture CUA a été tronquée : **rendu sombre français NON OBSERVÉ** pour cette tentative.
- `073510` : tentative UNKNOWN française arrêtée sur son seul hôte après absence de démarrage XCTest ; échantillon bloqué dans `dyld`/`open`, avant le code applicatif. Exit65 après SIGTERM, NON CONCLUANT. Reprise `073816` interrompue par concurrence après 72,989 s, sans résultat test ; qualification visuelle UNKNOWN encore ouverte.

[Reçus, sources et observations](evidence/visible-ui-20260921/). Les captures réelles CUA restent dans la trace de conversation ; aucun PNG exporté au dépôt n’est présenté comme leur équivalent. VoiceOver parlé, navigation clavier complète, transport réel, providers réels et upgrade/rollback complet restent ouverts. Les tests de diff utilisent un échec réel sur répertoire sans worktree puis des états chargés injectés : ils ne démontrent pas une réparation Git réelle.


### Régression finale et limites restantes à 08:07

Huit tests Assistant/Intégration PASS dans chacun des lancements EN et FR (`080145`, `080433`), zéro échec/skip. Les états UNKNOWN/diff ont donc une preuve automatisée courante ; leur inspection dans une vraie fenêtre reste ouverte. Nouvelle tentative `080545` arrivée au marqueur UNKNOWN, mais interrompue par concurrence avant observation : aucune preuve visuelle supplémentaire. Accueil sombre FR, VoiceOver parlé, navigation complète, transport réel et upgrade complet restent non qualifiés. Archive universelle corrigée et bundle structurel PASS, sans effet sur ces limites.


## Revue réelle complémentaire du 21 septembre, 08:10–08:26

Fenêtres isolées du build `072929`, avant extraction de lint : `081045` UNKNOWN FR sombre, motif lisible et vérification désactivée ; `081642` diff EN clair, erreur et Retry lisibles après agrandissement de la fenêtre de fixture ; `081853` accueil Assistant FR sombre, quatre suggestions lisibles sans troncature. Trois tests terminés PASS. Le Retry conserve l’erreur attendue du worktree absent ; aucun succès Git réel déduit. Les observations viennent des captures UI de la conversation, pas des PNG cacheDisplay défectueux.

Navigation clavier partielle seulement : focus éditeur observé ; Tab insère une tabulation dans le NSTextView multiligne. Le parcours complet reste non qualifié. VoiceOver a été temporairement activé puis remis OFF (état AX observé, volume inchangé). L’outil ne pouvait pas lire le panneau d’annonces : aucune validation vocale revendiquée et aucune écoute demandée à l’utilisateur. Le test `082358` PASS ne valide que les assertions de localisation. [Trace de la limite](evidence/visible-ui-20260921/voiceover-attempt.json).

La tentative `081200` a été interrompue par un xcodebuild tiers. Les refactorisations de lint suivantes exigent une nouvelle régression sur le candidat reconstruit.


## Régression et isolation TCC — 21 septembre,09:38

Le candidat Debug reconstruit `084810` a désormais **84 cas natifs distincts PASS en neuf suites** puis **8 répétitions FR PASS**, incluant les vues Assistant/Plan et l’accueil localisé. [Couverture contrôlée](evidence/native-refactor-20260921/isolated-combined-coverage.json). Ce sont des assertions XCTest/AX ; les observations visuelles précédentes restent attachées à leur ancien snapshot. Pas de nouvelle preuve vocale ou de parcours clavier complet.

L’ancien hôte externe portait l’identité de production `com.lorislab.throttle` avec une signature ad hoc. Les journaux TCC démontrent des demandes alternées causées par les exigences de signature incompatibles. Nouvel hôte interne `com.lorislab.throttle.test-host`, temporaires/résultats internes, anciens runners retirés. Aucun changement de permissions système par l’agent ; aucune modification ni relance de l’app installée. [Diagnostic](evidence/native-refactor-20260921/removable-volume-diagnosis.json), [contrôle TCC](evidence/native-refactor-20260921/tcc-post-isolation.json) : zéro prompt/conflit Throttle observé entre09:22:45 et09:29:10, sans garantie générale sur des accès futurs.

## Diagnostic clavier — 21 septembre,11:40

Référence : [matrice consolidée](RELEASE-GATE-MATRIX.md). Deux répétitions du cas diff EN ont passé les assertions XCTest (112157,112442), avec1047 sources identiques au build100452. Navigation clavier activée après puis avant le lancement sur accord précis ; Tab/Maj-Tab n'ont pas donné de focus Retry observable. OFF restauré et confirmé via AX, aucune nouvelle activation VoiceOver.

Un témoin autonome sans modèles/services Throttle confirme Tab/Espace sur NSButton puis bouton SwiftUI, compteur0→1 et log d'activation. Il ne qualifie pas le cockpit, mais exclut l'hypothèse générale d'une transmission impossible des touches. Les fenêtres Cockpit/Project activent NSApp et une policy regular ; HostedViewReview ne faisait que makeKeyAndOrderFront. Fixture alignée sur ce chemin, diagnostic limité aux booléens d'activation/focus et type du responder. Typecheck Swift6 et lint ciblé PASS ; rebuild/runtime NON EXÉCUTÉS après correction faute d'espace.

[Observations](evidence/release-finalization-20260921/keyboard-observations.json), [témoin](evidence/release-finalization-20260921/keyboard-probe-summary.json), [delta de fixture](evidence/release-finalization-20260921/fixture-source-delta.json). [Apple WWDC22](https://developer.apple.com/videos/play/wwdc2022/10075/), relue le21septembre, recommande de tester la navigation système ON et OFF ; elle n'établit pas la cause de ce cas.

## Essai après déplacement des caches —12:03

L'essai114959 PASS sur le build114759 confirme que l'activation de l'app ne suffit pas : NSApp active et fenêtre key, navigation système ON, firstResponder reste NSWindow. Le montage de la fixture a donc été aligné sur le NSHostingController et le style initial des fenêtres produit ; message synthétique distinct avant Retry. Build115329 et lint global854fichiers PASS, aucun changement produit. Runtime de cette seconde correction NON EXÉCUTÉ pour réserve disque insuffisante. OFF restauré ; [état précis et delta](evidence/release-finalization-20260921/post-cache-state.json). La preuve clavier reste ouverte.

## Reprise 21 septembre, 12:14

Les deux déplacements autorisés sont terminés (14 444 entrées vérifiées). Test clavier120437 PASS : Tab → Retry, Espace → rafraîchissement, Tab → nouveau Retry ; navigation système OFF restaurée. Les8 tests120630 ont révélé2 échecs de capture UNKNOWN (assertions fonctionnelles passent). Correctif de dimensionnement compilé121114 PASS, lint ciblé strict PASS ; runtime corrigé encore non exécuté faute de réserve pour le nouvel hôte. Archive signée locale en cours sous garde-fous, aucun résultat acquis. Voir la [matrice consolidée](RELEASE-GATE-MATRIX.md) pour les gates courants. Aucun upload ni restart installé.

## Arrêt borné —21 septembre,12:22

Archive121313 interrompue par concurrence après470,634s,1047 sources stables ; pas de PASS. Environ1,3Go libres, admission2Gio non satisfaite. Cache relocation terminée ; Retry clavier PASS limité ; correctif de capture compile, les8 tests corrigés restent NON EXÉCUTÉS. Aucun processus détenu volontairement laissé en arrière-plan. Voir [état courant et reprise](RELEASE-GATE-MATRIX.md).

## Revalidation de fixture —21 septembre,12:42

Build123340 PASS16,369s,1047 sources stables. sizingOptions seul ne suffisait pas (123001 :6/8 PASS) ; conteneur VStack et surface420x420 explicites corrigent les deux captures UNKNOWN, assertions conservées. Campagnes123427EN et123449FR :8/8 PASS chacune,0échec/skip, résultats xcresult extraits. Cas clavier123619 :1/1 PASS, Tab/Espace/Tab observés via CUA ; Navigation clavier OFF restaurée. Ces17 exécutions correspondent à8 cas distincts. Aucun changement produit ni restart installé.

Les anciens artefacts cockpit-maintenance du7septembre ont été préservés sur DeveloperStorage avec empreintes/modes/liens/attributs vérifiés, lien à l’ancien chemin, retrait du seul doublon. Contact de confidentialité existant retrouvé :support@lorislab.fr sous LorisLabs/LorisLabs Team ; identité juridique toujours non précisée dans le texte public. [Matrice courante](RELEASE-GATE-MATRIX.md).
