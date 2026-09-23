# Confidentialité Throttle — texte préparatoire, non publié

21 septembre 2026. Ce texte décrit les flux vérifiés dans le source du candidat 3.8.0 (227), encore non compilé nativement. Le DMG226 ne contient pas le correctif optimiseur. Il ne remplace pas une politique opérateur approuvée. Les éléments à résoudre figurent à la fin, sans durée de conservation inventée.

## Français

Présentation conservée : **LorisLabs**. Contact : **support@lorislab.fr**.

Throttle conserve sur votre Mac son historique d’utilisation, ses données de projet et ses journaux de tâches. Research Vault, lorsqu’il est activé, conserve les recherches importées dans une base locale chiffrée, avec une clé dans le trousseau macOS. Les sessions et leurs fichiers peuvent aussi être conservés par les outils que vous lancez.

Le traitement de l’Assistant dépend du fournisseur que vous choisissez. Un modèle sur le Mac traite la demande localement. Un serveur Ollama ou un fournisseur externe reçoit les messages, le contexte sélectionné et les résultats d’outils inclus dans la demande. Examiner une proposition avant de l’appliquer contrôle la modification locale ; cela ne signifie pas que sa génération n’a envoyé aucune donnée. Arrêter une réponse ne rappelle pas les données déjà transmises et ne garantit pas l’arrêt du traitement distant. La conservation chez ces fournisseurs dépend de leurs conditions et de votre configuration.

L’activation et l’actualisation d’une licence transmettent au service de licences LorisLabs une clé de licence, une empreinte de l’appareil et la version de l’application ; une ancienne empreinte peut être jointe pour rapprocher l’activation existante. Désactiver un appareil libère son activation ; cette opération n’équivaut pas à effacer le dossier d’achat. Le code du service associe également la licence à une adresse électronique et à des références de paiement. L’envoi du courriel de licence utilise Brevo ; les paiements utilisent Stripe et le service est hébergé sur Cloudflare. Les accès de ces prestataires et leur conservation effective doivent être explicités dans la politique finale.

Les mises à jour interrogent le serveur de distribution LorisLabs suivant les réglages Sparkle ; les contrôles automatiques sont activés dans la configuration source. Ces connexions ne sont pas une fonction d’analyse publicitaire. Le code de l’application ne comporte pas de SDK de publicité ou de télémétrie tierce.

Le miroir compagnon utilise votre base privée CloudKit quand vous l’activez. L’arrêt du miroir et la suppression des données déjà publiées sont deux opérations distinctes ; la suppression peut échouer si iCloud est indisponible. Le contrôle du terminal requiert une permission séparée. Les sessions déportées utilisent le serveur que vous configurez et peuvent y conserver sorties de terminal, transcriptions et fichiers transférés.

Supprimer seulement l’application ne doit pas être présenté comme une suppression automatique de tous les journaux, sauvegardes, éléments du trousseau, dossiers d’achat ou copies distantes. Conservez les journaux de projet avant une récupération ; ne supprimez pas des événements inconnus pour contourner un blocage.

L’optimiseur de configurations garde les fichiers settings dans ses vérifications déterministes locales. L’édition de CLAUDE.md par IA nécessite un modèle sur le Mac ; un fournisseur distant sélectionné dans Assistant ne reçoit pas ce fichier par ce parcours. Le choix de fournisseur est conservé.

## English

Existing public name retained: **LorisLabs**. Contact: **support@lorislab.fr**.

Throttle stores its usage history, project data and task journals on your Mac. When enabled, Research Vault stores imported research in an encrypted local database with a key in macOS Keychain. The tools you launch may also retain their own session files.

Assistant processing follows the provider you select. An on-device model processes the request locally. An Ollama server or external provider receives the messages, selected context and tool results included in the request. Reviewing a proposal before applying it controls the local change; it does not mean its generation transmitted no data. Stopping a response cannot recall data already sent or guarantee that remote processing stops. Remote retention depends on the provider's terms and your configuration.

License activation and refresh send a license key, device fingerprint and app version to LorisLabs' license service; a previous fingerprint may be included to reconcile an existing activation. Deactivating a device releases its activation and does not erase the purchase record. The service source also associates licenses with an email address and payment references. License delivery uses Brevo, payments use Stripe and the service runs on Cloudflare. Their effective access and retention must be specified in the final policy.

Update requests follow Sparkle settings and contact LorisLabs' distribution server; automatic checks are enabled in the source configuration. The app source contains no advertising or third-party telemetry SDK. Optional companion mirroring uses your private CloudKit database. Disabling mirroring and deleting an existing record are separate operations; deletion can fail while iCloud is unavailable. Terminal control requires separate permission. Remote sessions use your configured server, which may retain terminal output, transcripts and transferred files.

Removing the app alone must not be described as automatically deleting all journals, backups, Keychain entries, purchase records or remote copies. Preserve project journals before recovery; do not remove unknown events to bypass a blocked operation.

The configuration optimizer keeps settings files in deterministic local checks. AI editing of CLAUDE.md requires an on-device model; a remote provider selected in Assistant does not receive the file through this flow. The provider preference is preserved.

## Contact existant et continuité

Décision utilisateur du 21 septembre 2026 : « nom legal je prefere qu on reste comme on etait avant pour le moment ». Conserver la présentation historique LorisLabs / LorisLabs Team et le contact existant ; ne pas ajouter le nom personnel ni inventer une raison sociale. Le choix de présentation est acté, sans nouvelle demande de choix d'identité pour poursuivre la préparation. La confirmation de l'identité juridique est différée ; cette décision ne constitue ni une preuve de statut juridique ni une validation de conformité. Les autres faits de confidentialité restent à établir séparément. Aucun texte public modifié.

La politique publique existante présente « LorisLabs / LorisLabs Team » et le contact `support@lorislab.fr`. Adresse retrouvée dans la copie publique conservée, section Data Controller reconsultée en ligne le21septembre. Ce contact est repris dans la préparation ; aucun nouveau compte n’est nécessaire. Le fonctionnement de la boîte n’a pas été testé et son existence ne précise pas quelle personne ou société exploite LorisLabs.

Les conditions publiques indiquent encore que tous les achats passent par Apple ; le source de licence Throttle utilise Stripe. La section Throttle doit donc décrire le canal de vente réel et le contact de traitement applicable avant publication, sans inventer de nouvelles conditions commerciales. [Conditions actuelles](https://lorislab.fr/terms.html), relues le21septembre.

## Faits opérateur encore requis avant publication

### Proposition opérationnelle — à valider, non déployée

La recommandation est de minimiser les données et de rendre leur cycle de vie vérifiable, plutôt que d'annoncer une durée arbitraire. Un seul contact de confidentialité peut suffire au départ ; il doit être effectivement surveillé et attribué à l'entité qui exploite le service. Aucun compte de messagerie créé par cette revue.

- Associer chaque catégorie à une finalité et à une durée ou un critère documenté. Pour la licence, distinguer le droit d'utilisation à maintenir, les appareils activés, les données d'achat et les journaux de sécurité. Une licence durable ne justifie pas la conservation illimitée de toutes les traces.
- Séparer les données nécessaires au service des archives obligatoires à accès restreint. Une demande d'effacement ne permet pas de promettre la suppression de documents que la loi impose de conserver.
- Préparer un parcours support d'effacement : vérifier l'identité de façon proportionnée, inventorier les systèmes concernés, appliquer les suppressions autorisées, traiter les copies/prestataires et sauvegardes selon leurs contraintes, puis fournir un résultat précis et les exceptions justifiées. Ne pas confondre désactivation d'un Mac et effacement de l'achat.
- Tester la procédure sur une licence synthétique dédiée avant de la présenter comme disponible. Une opération partielle ou un prestataire indisponible doit rester en attente de réconciliation ; une nouvelle tentative ne doit pas recréer les données supprimées.
- Conserver une preuve minimale de traitement de la demande, sans recopier dans le reçu les données que l'on vient d'effacer. Définir aussi la conservation de ce reçu. Aucune donnée de client réel n'est nécessaire pour préparer ce protocole.

Cette proposition ne choisit pas l'entité juridique, ne fixe pas de nouvelles conditions contractuelles et ne modifie pas le backend externe. Les durées et les exceptions doivent correspondre à la situation de l'opérateur et aux obligations applicables. La CNIL distingue durée liée à la finalité et archivage intermédiaire ; le délai de réponse à une demande ne doit pas être présenté comme une preuve d'effacement déjà réalisé. Sources primaires relues le 21 septembre 2026 : [durées de conservation](https://www.cnil.fr/fr/passer-laction/les-durees-de-conservation-des-donnees), [droit à l'effacement](https://www.cnil.fr/fr/comprendre-mes-droits/le-droit-leffacement-supprimer-vos-donnees-en-ligne), [information et transparence](https://www.cnil.fr/fr/conformite-rgpd-information-des-personnes-et-transparence).

### Faits qui restent à établir

| Élément | État vérifié | Condition de clôture |
|---|---|---|
| Révision du service | `/api/health` répond HTTP 200 `ok`. Lecture Wrangler des déploiements exit 1, sans métadonnées exploitables. | Identifier la révision réellement déployée et la comparer au source audité ; aucune lecture de dossiers clients n’est nécessaire. |
| Conservation licence | Code local : pas de TTL sur le dossier de licence ; désactivation conserve achat et email. Éviction après 90 jours uniquement conditionnelle à une nouvelle activation au quota, pas suppression périodique. | Faire approuver une durée ou un critère de conservation et vérifier son application. Ne pas annoncer une purge à 90 jours. |
| Effacement | Aucun endpoint d’effacement complet identifié dans ce source. | Procédure opérateur vérifiée pour licence, index email, paiement et courriel ; préciser obligations de conservation et délais sans inventer une API inexistante. |
| Responsable/contact | Présentation historique LorisLabs / LorisLabs Team et `support@lorislab.fr` conservés sur décision utilisateur du 21 septembre. Identité juridique non confirmée, clarification différée. Le certificat Apple ne prouve pas le responsable juridique du service. | Respecter ce choix dans les brouillons ; ne pas redemander le même choix pour continuer. La qualification juridique et le traitement effectif des demandes par cette boîte restent non vérifiés. Aucun nouveau contact à créer par défaut. |
| Prestataires | Cloudflare, Stripe et Brevo présents dans le code local. | Confirmer configurations et engagements applicables au déploiement, sans extrapoler depuis leurs durées génériques. |
| Claude | Demande de l’utilisateur transférée au support humain, conversation `215476024504261`. | Adapter la liste des modes disponibles à la décision finale. Aucune approbation reçue, aucun changement de route effectué. |

## Références et portée

- [Cartographie source](../../PRIVACY.md), [textes de release](RELEASE-COPY-DRAFT.md).
- [Relectures publiques et empreintes](evidence/release-continuation-20260921/public-reads.json), [résultat de lecture Cloudflare](evidence/release-continuation-20260921/license-deployments.json).
- Source backend externe inspectée sans modification : `/Users/kevinnadjarian/GitHub/throttle-license-worker/src/index.ts`, `handleDeactivate`, `handleActivate`, `kvLicenseRepository`, `sendLicenseEmail`; dépôt local sale, HEAD `1201b11`. Sa présence ne prouve pas son déploiement.
- [Politique publique existante](https://lorislab.fr/privacy.html), relue le 21 septembre : aucune section Throttle trouvée ; ne pas publier ce brouillon comme si tous les faits opérateur étaient réglés.
