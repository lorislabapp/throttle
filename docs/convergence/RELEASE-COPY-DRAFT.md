# Textes de release progressive — brouillon local, non publié

21 septembre 2026. Candidat source 3.8.0 (226), supérieur au maximum 223 du flux consulté ; ce constat ne réserve pas un numéro. Ce document ne change aucun site ni engagement commercial.

## Écarts constatés sur le site public

La [page Throttle](https://lorislab.fr/throttle/), consultée le 21 septembre, affiche 3.7.2 et annonce Apple Silicon/Intel ainsi qu’un traitement exclusivement local. Ce dernier message est trop général pour le candidat qui permet le choix explicite de services externes. Les déclarations de signature/notarisation de la version publique ne qualifient pas le nouveau candidat.

Les pages [confidentialité](https://lorislab.fr/privacy.html) et [conditions](https://lorislab.fr/terms.html) liées par le site ne contiennent pas de section nommant Throttle dans le texte consulté. Leur contenu générique ne suffit pas à documenter les flux propres à Throttle. Aucune conclusion juridique ni nouvelle politique de rétention n’est inventée ici.

Le flux `https://lorislab.fr/throttle/appcast.xml` est désormais accessible (HTTP 200). Le maximum publié est 223 ; le candidat 226 le dépasse. L'ancien refus HTTP 403 reste une observation historique. Le gate vérifie aussi les anciens numéros numériques à points, dont `3.0.0`, sans ignorer les entrées invalides. [Snapshot et résultat](evidence/distribution-preflight-20260921/version-gate-result.json). Une nouvelle lecture est requise au staging pour éviter un résultat périmé.

## Note française proposée

Le cockpit rend plus clairs les résultats disponibles, les erreurs de lecture du diff et les vérifications encore sans résultat. L’assistant peut arrêter la consommation d’une réponse ; les réponses tardives ne doivent pas se mélanger avec une nouvelle demande ou un autre projet.

Le choix du traitement est explicite : sur le Mac quand un modèle local est sélectionné, ou auprès du serveur/fournisseur que vous choisissez. L’API Anthropic est facturée séparément selon le modèle et les jetons traités. Le miroir compagnon ne donne pas automatiquement le contrôle du terminal : cette permission reste séparée et révocable.

Cette version est destinée à la supervision de projets de confiance. Leurs commandes utilisent les droits du compte macOS ; Throttle ne les confine pas comme du code hostile. Une vérification dont le résultat est inconnu reste bloquée pour inspection. Arrêter une réponse ne garantit pas l’arrêt du traitement ou de la facturation côté fournisseur.

## Proposed English release note

The cockpit makes available evidence, diff errors and unresolved checks easier to distinguish. The Assistant can stop consuming a response; late output must not mix with a new request or another project.

Processing is selected explicitly: on your Mac with a local model, or through the server or provider you choose. Anthropic API usage is billed separately according to the model and tokens processed. Companion mirroring does not automatically grant terminal control; that permission is separate and revocable.

This version supervises trusted projects. Project commands run with your macOS account’s permissions; Throttle does not contain hostile code. Checks with an unknown outcome remain blocked for inspection. Stopping a response does not guarantee that a remote provider has stopped processing or billing.

## Informations à qualifier avant publication

- Garder la compatibilité Intel annoncée tant qu’aucune décision produit ne la modifie. L’archive universelle précédente contient arm64+x86_64 ; elle doit être renouvelée après les dernières corrections de licence et de journal, et ne prouve pas le fonctionnement sur un Mac Intel ou macOS 14.
- [Description source des flux](../../PRIVACY.md) : messages et contexte vers le fournisseur choisi, sessions déportées, miroir/contrôle compagnon, CloudKit opt-in, licence et Sparkle. Les durées de conservation des services déployés et leurs procédures de suppression ne sont pas vérifiées ; ne pas les inventer dans le texte public.
- Captures du candidat qualifié, numéro version/build, taille et empreinte DMG final, URL de support et responsable d’incident à reprendre des sources opérationnelles vérifiées.
- Les textes ci-dessus ne doivent être publiés qu’après réussite des parcours correspondants et autorisation distincte de publication.


## Mise à niveau et récupération — note technique à joindre

Le schéma de la base SQL et son code d’ouverture n’ont pas changé depuis le commit de release3.7.2(223) `d734b864ab83db050f4c55de2f94556e66308369`. Les journaux de tâches peuvent recevoir de nouveaux événements de vérification. Leur lecture par cette version conserve les anciens enregistrements et distingue les exécutions sans résultat.

Après création de ces nouveaux événements, remplacer seulement l’application par une ancienne version ne constitue pas un retour arrière sûr. Conserver les journaux et les dépôts ; ne pas effacer les événements inconnus pour débloquer une tâche. La réponse prévue à une régression est un correctif de version supérieure qui préserve ces données. Une restauration historique exige une sauvegarde cohérente du projet et une réconciliation des opérations réalisées depuis ; elle ne doit pas être automatique.

Cette conclusion compare les sources du commit223, sans prétendre établir l’identité de son DMG distribué. Les tests de compatibilité ont une portée synthétique documentée dans le rapport UX/QA.

## Compléments préparés à 10:46 — non publiés

- [Texte de confidentialité FR/EN](PRIVACY-PUBLIC-DRAFT.md), avec les faits opérateur réellement manquants.
- [Procédure de mise à niveau et récupération](RELEASE-RECOVERY.md), fondée sur quatre scénarios exécutés avec les deux lecteurs réels.
- [Patch de texte du site](evidence/release-continuation-20260921/website-copy.patch) et [empreintes/conditions d'application](evidence/release-continuation-20260921/website-copy-manifest.json) : trois descriptions de métadonnées et le paragraphe de confiance sont corrigés localement. Aucun prix, lien de téléchargement ou numéro de version changé. Ce patch n'est pas un stage publiable et ne remplace pas la politique de confidentialité à finaliser.
- Le support Anthropic a transmis la demande à une équipe humaine, conversation `215476024504261`, selon le message fourni par l'utilisateur. Aucune autorisation d'intégration reçue, aucune route modifiée en attendant.

## Révision complémentaire du texte public — préparation locale

Le [patch v2](evidence/release-finalization-20260921/website-copy-v2.patch) et son [manifeste](evidence/release-finalization-20260921/website-copy-v2-manifest.json) remplacent la proposition initiale de quatre zones pour la prochaine revue. Vingt-sept substitutions de texte et trois métadonnées bornent les promesses de prédiction, économie, confidentialité et réversibilité. Les 21 références URL, prix, scripts/styles, version et taille héritées du snapshot restent inchangés. Le HTML est un **brouillon non stagé**, pas une page validée pour upload ; version/taille seront celles du paquet définitif. L'original et le premier patch restent conservés.

La vérification porte sur l'intégrité de ces substitutions et l'absence de changement des liens/prix/exécutables, pas sur le rendu complet ni sur toutes les fonctionnalités commerciales héritées. Relecture de la source publique fraîche, décision Claude, politique opérateur finale et accord de publication restent nécessaires.
