# Vérification — identité des processus et limites de reprise

## Responsabilités et ordre réel

`PlanStore` conserve l'intention puis `verification_process_attached`. L'événement contient l'identité noyau existante (`NativeProcessIdentity` : PID, UID, parent et heure de naissance), le groupe et l'UUID du démarrage macOS. Aucun nouveau store autoritaire.

`TaskIntegrationServiceVerify` lance un wrapper fixe, bloqué sur la lecture d'un pipe privé avant tout code du projet. L'identité noyau et le lien parental sont capturés puis persistés. Le contrôleur écrit ensuite une permission éphémère `run\n`. S'il meurt avant cette écriture, la fermeture des descripteurs provoque EOF et le wrapper sort sans exécuter le projet. Une erreur d'attachement entraîne l'arrêt/récolte de cet enfant possédé. Aucun signal SIGCONT ni processus durablement suspendu n'est désormais nécessaire.

Deux fixtures exécutent réellement `_exit(71)` dans un contrôleur synthétique, avant puis après attachement : la commande marqueur n'est pas exécutée, l'enfant disparaît, le journal rouvert reste UNKNOWN et refuse un retry. Elles ne simulent pas seulement une exception Swift. Elles ne prouvent pas la récupération **après** la libération du pipe : les effets de la commande autorisée et ses descendants peuvent alors survivre.

`TaskIntegrationVerifyProcess.ChildControl` observe la fin avec WNOWAIT et réserve le PID jusqu'à la fin de l'escalade et du drainage. Le verrou commun refuse tout signal après récolte. Le diagnostic de groupe réutilise `OwnedProcessTermination.holdsOnlyZombies`. Un groupe absent ne prouve pas l'absence de descendants ayant changé de session/groupe. L'ancien texte promettant la fin de « every process » est retiré.

`TaskVerificationProcess.observe()` est une lecture, jamais une permission de signaler. Il distingue ROOT_PRESENT, ROOT_EXITED_DESCENDANTS_UNKNOWN, PID_REUSED_DESCENDANTS_UNKNOWN, DIFFERENT_BOOT_EXTERNAL_EFFECTS_UNKNOWN et UNAVAILABLE. Aucun état ne certifie le travail et aucune lecture ne libère une intention. Le PID avec heure de naissance limite la confusion d'identité ; ce n'est pas une poignée noyau atomique autorisant un kill après redémarrage.

## Contre-exemples et portée

- Un processus peut quitter son groupe, se détacher, lancer un daemon ou demander une opération distante. L'absence du root et même un nouveau boot ne réconcilient pas ces effets.
- Une liste de processus peut être interdite, incomplète ou changer pendant la lecture. Le résultat demeure UNAVAILABLE/UNKNOWN selon le cas ; aucune adoption d'un PID par simple numéro.
- La vérification qui réussit en laissant volontairement un processus de fond conserve le comportement existant. Sa réussite concerne la commande ; elle n'est pas une attestation d'arrêt des descendants.
- Aucun agent hostile du même UID n'est isolé par ce mécanisme. Il pourrait modifier les fichiers ou intervenir sur le processus admis. La qualification OS du harness reste nécessaire avant autonomie d'écriture.
- La lecture d'identité est branchée sur le journal et son diagnostic MCP. L'UI de reprise et la réconciliation des effets après crash réel restent à réaliser. Aucun nouvel écran ou bouton de relance aveugle.
- `OwnedProcessTermination` reste utilisé ailleurs pour l'arrêt de sessions ; cette tranche réutilise ses lectures noyau sans convertir ses snapshots en garanties de confinement.

## Sources primaires consultées le 20 septembre 2026

- En-tête [XNU spawn.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/spawn.h) et SDK local `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/sys/spawn.h` : drapeau Darwin public START_SUSPENDED constaté pour la première variante, désormais remplacée par le pipe. Le code Apple est consulté, pas copié dans Throttle.
- [XNU kern_exec.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_exec.c) : la branche du drapeau place le processus dans SSTOP et suspend la tâche avant exécution. C'est une explication fournisseur du mécanisme, complétée par les fixtures locales.
- [XNU proc_info.c](https://github.com/apple/darwin-xnu/blob/main/bsd/kern/proc_info.c) : provenance noyau des champs d'heure de naissance réutilisés par NativeProcessIdentity.
- Les pages web Open Group waitid et l'archive Apple waitid n'ont pas été accessibles avec l'outil de recherche. Aucune citation de leur contenu supposé. WNOWAIT est présent dans le SDK et exercé par les tests locaux ; aucune conclusion de portabilité Linux/Android.

Ces références justifient un mécanisme macOS local. Elles ne justifient ni exécuteur distribué, ni nouveau Decision Engine, ni migration Gateway.

## Incident de restauration et diagnostic

Le worktree initial et les preuves étaient dans `/private/tmp`. Après le redémarrage du 20 septembre à 21:31 heure locale, ces fichiers n'existaient plus. Les sources ont été reconstruites à partir des écritures de la session Codex, dans `build/convergence-recovery-20260920`, base Git identique et patch cockpit hérité préservé. Le journal de restauration conserve l'échec partiel connu du script 2679, suivi de ses corrections ; aucune compilation, requête réseau ou signal historique n'a été rejoué automatiquement.

Deux suites intermédiaires ont échoué avant ce redémarrage. Le test de timeout rapide a permis de constater CLD_STOPPED lors du lancement suspendu ; un PID renseigné dans siginfo avait été pris à tort pour une preuve de sortie. ChildControl vérifie maintenant CLD_EXITED/CLD_KILLED/CLD_DUMPED. La publication du timeout reste sous le verrou du signal. Les traces de diagnostic ne sont pas présentes dans le code restauré. Le résultat de la dernière suite interrompue n'est pas connu et n'est pas compté comme réussi.

## Vérification

Les résultats finaux et empreintes figurent dans [PROGRESS.md](PROGRESS.md). Les tests n'effectuent ni restart de Throttle, ni signal à une session utilisateur. Les processus arrêtés sont uniquement les descendants synthétiques créés par les fixtures.
