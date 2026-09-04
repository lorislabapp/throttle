# Audit de récupération — DeepSearsh et Research Vault

Date : 2026-09-04 (Europe/Paris)
Portée : la chaîne de récupération des deux systèmes, mesurée sur un golden set construit pour l'occasion
Statut : mesures locales reproductibles ; aucune preuve de release, aucun déploiement

## Ce que l'audit a changé dans le code

Trois défauts corrigés, chacun avec son test :

| Défaut | Où | Correctif |
|---|---|---|
| La recherche annonçait `hybrid-rrf` alors que la jambe dense ne contribuait rien | `DeepSearsh/scripts/search.py:176` | annonce `bm25-degraded` + raison actionnable |
| `verify.sh` imprimait `LIVE BENCHMARK SKIPPED` et sortait quand même en 0 | `Packages/ResearchVaultKit/Scripts/verify.sh` | sortie ≠ 0, opt-out explicite |
| Les mots vides décidaient du classement, dans les deux systèmes | `search.py`, `SQLCipherReceiptStore.safeFTSQuery` | filtrés, avec repli si la requête n'en contient que |
| `research_local_search` scorait des métadonnées, jamais l'index | `NotebookLM-SOTA-Gateway/DeepSearshStore.swift` | appelle le vrai moteur, repli étiqueté |

Et un état restauré : les binaires Swift de `DeepSearsh/ai-helper` avaient disparu du disque, ce qui vidait
silencieusement la jambe dense et laissait **7 737 chunks sur 28 102 sans vecteur**. Reconstruits, index
complété à 28 102/28 102.

## L'instrument de mesure

`DeepSearsh/eval/golden-v2` — deux sous-ensembles mesurés séparément, parce qu'ils ne révèlent pas les
mêmes défauts.

- **Dérivé du corpus** : 833 cas, 220 documents à titre unique × 4 variantes de requête, plus 10 requêtes
  absurdes dont la bonne réponse est le silence.
- **Vraies questions** : 60, extraites de 22 749 tours utilisateur, filtrées en deux passes puis étiquetées
  à la main.

Le jeu précédent (18 questions) était entièrement dérivé de titres. Ses requêtes sont des mots-clés, sans
mots vides — **il ne pouvait structurellement pas voir le défaut le plus coûteux du système**. C'est la
leçon de méthode de cet audit : un golden set qui ne ressemble pas aux vraies requêtes mesure le confort,
pas la qualité.

## Résultats — 60 questions, 43 répondables, 17 sans réponse

| variante | Recall@5 | MRR | nDCG@5 |
|---|---|---|---|
| BM25 sans mots vides | 0.557 | 0.359 | 0.405 |
| dense Qwen3-Embedding-0.6B | 0.533 | 0.416 | 0.405 |
| **RRF BM25 + dense** | **0.568** | **0.540** | **0.467** |

`VERIFIED` — les deux moteurs sont comparables et complémentaires ; la fusion RRF les bat tous deux sur
les trois métriques. Le dense classe mieux ce qu'il trouve, et atteint des documents que BM25 ne peut pas
atteindre : « quel modèle vocal sur Mela » retrouve *Voice Cloning vs Apple Personal Voice* sans partager
un seul mot.

`VERIFIED` — le modèle d'embedding précédent était le mauvais outil, pas une mauvaise idée. Apple
`NLEmbedding` n'est pas entraîné pour la récupération asymétrique, et ses espaces anglais (512-d) et
français (640-d) sont **disjoints** : une question française ne pouvait atteindre aucun document anglais.
La conclusion « le dense n'apporte rien », gravée dans l'ADR-0001 §7, reposait sur cette mesure.

## Deux erreurs de méthode commises pendant l'audit, consignées parce qu'elles instruisent

**Biais de pooling.** Les premiers chiffres donnaient BM25 à 0.952 et le dense à 0.194. Les deux étaient
faux : les candidats soumis au jugement ne venaient que de variantes BM25, donc 83 % des documents que le
dense remontait n'avaient jamais été vus par un juge et comptaient comme non pertinents par défaut.

**Couverture confondue avec récupération.** La part de questions « sans réponse dans le corpus » a chuté de
48 % à 28 % au fil de l'étiquetage. **Treize questions sur soixante étaient des échecs de récupération, pas
des absences de couverture.** L'orientation stratégique qui en découlait — investir dans l'acquisition — était
fausse aux deux tiers.

## L'abstention reste non résolue

`VERIFIED` — aucun signal bon marché ne fonctionne sur ce corpus :

| signal | exactitude (validation croisée) |
|---|---|
| répondre toujours | 60,0 % |
| seuil sur le score BM25 | 58,3 % |
| seuil sur le cosinus absolu | 65,0 % |
| marge top1−top2 | 60,0 % |

BM25 ne peut pas porter l'abstention : il mesure la correspondance des mots, pas si le document répond.
La marge échoue pour une raison structurelle — les candidats d'une même requête sont lexicalement proches,
donc leurs scores sont agglutinés, contrairement au cas des probabilités de sous-objectifs discrets où
cette technique est décrite.

`HYPOTHESIS` — les deux pistes qui restent, tirées de la littérature et non encore mesurées ici : le seuil
adaptatif par élément, et le jugement par cross-encoder ou verdict contraint calibré par log-probabilité.

## Chemin SOTA, par ordre d'impact

1. **Récupération en deux étages** : BM25 + dense fusionnés par RRF, puis un reranker. C'est le seul chemin
   mesuré au-delà de 85 % dans la littérature, et aucun de nos deux moteurs seul ne dépasse 0.57 de recall.
2. **Abstention sur le score du reranker**, seuil adaptatif, calibration mesurée en ECE et non en exactitude.
3. **Contextual Retrieval** sur le corpus curatif seulement — frontier une fois par document à l'ingestion,
   local sur le flux.
4. **Brancher le Vault** et lui donner la propriété de l'index. Le package est écrit, compilé et testé ; il
   n'est raccordé à rien.

## Ce qu'il ne faut pas conclure

- Le gain du retrait des mots vides n'est **pas** établi statistiquement. Le recall moyen monte nettement,
  mais Wilcoxon donne p = 0.041 sur une voie et 0.101 sur l'autre, et deux tests appellent un seuil corrigé
  de 0.025. Le correctif a été appliqué comme **défaut**, pas comme challenger promu.
- Aucune de ces mesures n'est une preuve de release, de signature, de notarisation ou de distribution.

## Reproduire

    cd ~/GitHub/DeepSearsh/eval/golden-v2 && python3 evaluate.py
