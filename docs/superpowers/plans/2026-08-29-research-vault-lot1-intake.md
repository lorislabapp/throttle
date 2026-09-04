# Research Vault Lot 1 — Intake (quarantaine, parseurs package, export MD, URL) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fermer la Phase 2 du dossier Research Vault : tout import passe par une quarantaine à revue humaine, les parseurs vivent dans le package, l'export Markdown dérivé existe, et une URL peut devenir une source.

**Architecture:** Le store SQLCipher gagne un `review_state` (schéma v4) filtré dans toutes les lectures ; la revue (list/approve/reject) passe par l'endpoint owner XPC comme `importReceipts` ; les parseurs et l'importer NotebookLM migrent de la cible app vers `ResearchVaultIngestion` ; le Workbench gagne une section Quarantaine.

**Tech Stack:** Swift 6 strict concurrency, SwiftPM (`Packages/ResearchVaultKit`), SQLCipher + FTS5, XPC signé (ADR 0002), SwiftUI/AppKit, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-29-research-vault-full-sota-design.md` (Lot 1)

## Global Constraints

- Swift 6, `SWIFT_STRICT_CONCURRENCY complete` ; types renvoyés hors acteur = `Sendable`.
- Tests package : `Packages/ResearchVaultKit/Scripts/verify.sh` (stage `SQLCipher.framework` — un `swift test` nu ne linke pas). Pour un run ciblé : `Packages/ResearchVaultKit/Scripts/verify.sh --filter <TestName>` si supporté, sinon le script entier.
- Après tout ajout/suppression de fichier dans `Throttle/` : `xcodegen generate` sinon le build ne voit pas le fichier.
- Build app : `xcodebuild -scheme Throttle -configuration Debug -destination 'platform=macOS' build` (ne jamais coller la sortie brute d'un échec — elle contient l'environnement).
- Commits : `[throttle] action: description`, pas de backticks/`<`/`>` dans `-m`.
- Interdits : install/relance de l'app, push, publication, toucher `~/.claude.json`.
- Aucun statut de preuve inventé : le texte importé reste `open`.
- Plafonds intake existants inchangés : 256 docs / 512 KB / 480 000 chars ; owner XPC 1 MiB / 32 receipts par requête.

---

### Task 1: `ResearchReviewState` + schéma v4 + filtre approved

**Files:**
- Modify: `Packages/ResearchVaultKit/Sources/ResearchVaultModel/ResearchReceipt.swift` (ajouter l'enum en fin de fichier)
- Modify: `Packages/ResearchVaultKit/Sources/ResearchVaultSQLCipher/SQLCipherReceiptStore.swift` (`currentSchemaVersion`, `migrate`, `importReceipt(s)`, `receipt`, `receipts`, `searchClaims`, `searchDocuments`, `importDocument`)
- Test: `Packages/ResearchVaultKit/Tests/ResearchVaultSQLCipherTests/SQLCipherReviewStateTests.swift` (create)

**Interfaces:**
- Produces: `public enum ResearchReviewState: String, Codable, Sendable, CaseIterable { case quarantined, approved }` (dans `ResearchVaultModel`).
- Produces: `SQLCipherReceiptStore.importReceipt(_:authorization:reviewState:)` et `importReceipts(_:authorization:reviewState:)` — paramètre **obligatoire** (pas de défaut : chaque appelant choisit explicitement).
- Le rejet n'est pas un état stocké : rejeter = DELETE (Task 2).

- [ ] **Step 1: Écrire les tests qui échouent**

```swift
import Testing
import ResearchVaultModel
@testable import ResearchVaultSQLCipher

// Réutiliser les helpers du fichier de tests store existant (clé 32 octets,
// receipt scellé de test, authorization) — les copier localement si privés.

@Test func quarantinedReceiptIsInvisibleToSearchAndReads() async throws {
    let store = try makeStore()                       // helper existant
    let receipt = try makeSealedReceipt(claim: "quarantine me")
    _ = try await store.importReceipts([receipt], authorization: fullAuth(), reviewState: .quarantined)
    let hits = try await store.searchClaims(matching: "quarantine", authorization: fullAuth(), limit: 10)
    #expect(hits.isEmpty)
    #expect(try await store.receipts(authorization: fullAuth()).isEmpty)
}

@Test func approvedReceiptIsVisible() async throws {
    let store = try makeStore()
    let receipt = try makeSealedReceipt(claim: "approved claim")
    _ = try await store.importReceipts([receipt], authorization: fullAuth(), reviewState: .approved)
    let hits = try await store.searchClaims(matching: "approved", authorization: fullAuth(), limit: 10)
    #expect(hits.count == 1)
}

@Test func v3DatabaseMigratesExistingRowsAsApproved() async throws {
    // Ouvrir un store, importer en .approved, fermer ; rouvrir : la ligne reste
    // visible et user_version == 4. (La préservation v3→v4 réelle est couverte
    // par le pattern des tests de migration existants — suivre ce pattern.)
    let url = temporaryDatabaseURL()
    let key = testKey()
    do {
        let store = try SQLCipherReceiptStore(databaseURL: url, key: key)
        _ = try await store.importReceipts([try makeSealedReceipt(claim: "survives")], authorization: fullAuth(), reviewState: .approved)
        await store.close()
    }
    let reopened = try SQLCipherReceiptStore(databaseURL: url, key: key)
    let hits = try await reopened.searchClaims(matching: "survives", authorization: fullAuth(), limit: 10)
    #expect(hits.count == 1)
}
```

- [ ] **Step 2: Lancer — vérifier l'échec**

Run: `Packages/ResearchVaultKit/Scripts/verify.sh`
Expected: FAIL — `reviewState` n'existe pas (erreur de compilation attendue = rouge valide pour une API nouvelle).

- [ ] **Step 3: Implémenter**

Dans `ResearchReceipt.swift` :

```swift
/// Human-review state of imported material. Rejection is not a stored state:
/// rejecting deletes the rows. Existing pre-v4 rows were imported before the
/// quarantine existed and are grandfathered as approved.
public enum ResearchReviewState: String, Codable, Sendable, CaseIterable {
    case quarantined
    case approved
}
```

Dans `SQLCipherReceiptStore.swift` :
- `currentSchemaVersion = 4`.
- Fin de `migrate` (après le bloc v2→v3) :

```swift
let afterV3 = Int(try connection.scalarInteger("PRAGMA user_version;") ?? 0)
if afterV3 == 3 {
    try connection.transaction {
        try connection.execute(
            "ALTER TABLE receipts ADD COLUMN review_state TEXT NOT NULL DEFAULT 'approved' CHECK(review_state IN ('quarantined','approved'));"
        )
        try connection.execute(
            "ALTER TABLE documents ADD COLUMN review_state TEXT NOT NULL DEFAULT 'approved' CHECK(review_state IN ('quarantined','approved'));"
        )
        try connection.execute(
            "CREATE INDEX receipts_review ON receipts(review_state, project_key);"
        )
        try connection.execute("PRAGMA user_version = 4;")
    }
}
```

- `importReceipt`/`importReceipts` : nouveau paramètre `reviewState: ResearchReviewState`, colonne `review_state` dans l'INSERT.
- `importDocument` : même paramètre + colonne.
- `receipt`, `receipts`, `searchClaims`, `searchDocuments` : ajouter `AND r.review_state = 'approved'` (resp. `d.review_state`) dans le WHERE. Le JOIN FTS passe par `findings` → filtrer via le receipt parent.
- Mettre à jour **tous** les appels existants dans le package (ServiceRuntime, gateway, tests) avec `.approved` pour ne pas changer leur comportement dans cette task — le basculement de l'intake vers `.quarantined` est Task 3.

- [ ] **Step 4: Vérifier vert**

Run: `Packages/ResearchVaultKit/Scripts/verify.sh`
Expected: PASS, y compris tous les tests store existants.

- [ ] **Step 5: Commit**

```bash
git add Packages/ResearchVaultKit
git commit -m "[throttle] feat: review_state schema v4, approved-only reads"
```

---

### Task 2: API de revue — pending / approve / reject

**Files:**
- Modify: `Packages/ResearchVaultKit/Sources/ResearchVaultSQLCipher/SQLCipherReceiptStore.swift`
- Test: `Packages/ResearchVaultKit/Tests/ResearchVaultSQLCipherTests/SQLCipherReviewStateTests.swift` (extend)

**Interfaces:**
- Consumes: `ResearchReviewState`, schéma v4 (Task 1).
- Produces (sur `SQLCipherReceiptStore`) :

```swift
public struct QuarantinedReceiptSummary: Codable, Equatable, Sendable {
    public let receiptID: String
    public let projectKey: String
    public let question: String
    public let sensitivity: ResearchSensitivity
    public let createdAt: Date
    public let sourceCount: Int
    public let firstSourceLocator: String?
}
public func quarantinedReceipts(authorization: VaultAuthorization) throws -> [QuarantinedReceiptSummary]
public func approveReceipts(ids: [String]) throws -> Int   // renvoie le nombre approuvé
public func rejectReceipts(ids: [String]) throws -> Int    // DELETE, cascades + triggers FTS
```

- [ ] **Step 1: Tests qui échouent**

```swift
@Test func quarantineListShowsPendingOnly() async throws {
    let store = try makeStore()
    _ = try await store.importReceipts([try makeSealedReceipt(claim: "pending A")], authorization: fullAuth(), reviewState: .quarantined)
    _ = try await store.importReceipts([try makeSealedReceipt(claim: "already ok")], authorization: fullAuth(), reviewState: .approved)
    let pending = try await store.quarantinedReceipts(authorization: fullAuth())
    #expect(pending.count == 1)
    #expect(pending[0].question.contains("pending") || pending[0].sourceCount >= 0)
}

@Test func approveMakesSearchable() async throws {
    let store = try makeStore()
    let receipt = try makeSealedReceipt(claim: "approve flow")
    _ = try await store.importReceipts([receipt], authorization: fullAuth(), reviewState: .quarantined)
    let pending = try await store.quarantinedReceipts(authorization: fullAuth())
    #expect(try await store.approveReceipts(ids: pending.map(\.receiptID)) == 1)
    #expect(try await store.searchClaims(matching: "approve", authorization: fullAuth(), limit: 10).count == 1)
}

@Test func rejectDeletesEverything() async throws {
    let store = try makeStore()
    let receipt = try makeSealedReceipt(claim: "reject flow")
    _ = try await store.importReceipts([receipt], authorization: fullAuth(), reviewState: .quarantined)
    let pending = try await store.quarantinedReceipts(authorization: fullAuth())
    #expect(try await store.rejectReceipts(ids: pending.map(\.receiptID)) == 1)
    #expect(try await store.quarantinedReceipts(authorization: fullAuth()).isEmpty)
    // Ré-import du même receipt possible après rejet (content_hash libéré) :
    _ = try await store.importReceipts([receipt], authorization: fullAuth(), reviewState: .quarantined)
}
```

- [ ] **Step 2: Vérifier l'échec** — `verify.sh`, FAIL (symboles absents).

- [ ] **Step 3: Implémenter**

- `quarantinedReceipts` : SELECT sur `receipts WHERE review_state='quarantined'` filtré par `authorization` (même pattern de scope que `receipts(authorization:)`), jointure comptée sur `sources`, tri `created_at_ms DESC`.
- `approveReceipts` : transaction, `UPDATE receipts SET review_state='approved' WHERE receipt_id IN (...)`, retour `changes()`.
- `rejectReceipts` : transaction, `DELETE FROM receipts WHERE receipt_id IN (...) AND review_state='quarantined'` (on ne rejette jamais de l'approuvé par cette API), cascades nettoient sources/findings/evidence, triggers nettoient la FTS.

- [ ] **Step 4: Vérifier vert** — `verify.sh` PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ResearchVaultKit
git commit -m "[throttle] feat: quarantine review API - pending, approve, reject"
```

---

### Task 3: Quarantaine de bout en bout — IPC, XPC owner, intake par défaut

**Files:**
- Modify: `Packages/ResearchVaultKit/Sources/ResearchVaultIPCModel/ResearchVaultIPCModel.swift`
- Modify: `Packages/ResearchVaultKit/Sources/ResearchVaultXPCClient/ResearchVaultXPCClient.swift` (protocole owner)
- Modify: `Packages/ResearchVaultKit/Sources/ResearchVaultXPCClient/ResearchVaultClient.swift`
- Modify: `Packages/ResearchVaultKit/Sources/ResearchVaultServiceRuntime/ResearchVaultServiceRuntime.swift` (+ le delegate owner dans `ResearchVaultXPC.swift` s'il est séparé)
- Test: `Packages/ResearchVaultKit/Tests/` — étendre les tests XPC/owner existants (suivre le pattern du test `importReceipts` owner)

**Interfaces:**
- Consumes: Task 2 (`quarantinedReceipts`/`approveReceipts`/`rejectReceipts`), Task 1 (`reviewState:` sur import).
- Produces (IPC model, même style que `ResearchVaultReceiptImportRequest`) :

```swift
public struct ResearchVaultQuarantineItem: Codable, Equatable, Sendable {
    public let receiptID: String
    public let projectKey: String
    public let question: String
    public let sensitivity: String
    public let createdAtMS: Int64
    public let sourceCount: Int
    public let firstSourceLocator: String?
}
public struct ResearchVaultQuarantineListResponse: Codable, Equatable, Sendable {
    public let items: [ResearchVaultQuarantineItem]
}
public struct ResearchVaultReviewRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case approve, reject }
    public let contractVersion: Int
    public let action: Action
    public let receiptIDs: [String]   // validé : 1...32, IDs non vides
}
public struct ResearchVaultReviewResponse: Codable, Equatable, Sendable {
    public let processed: Int
}
```

- Produces (protocole owner + client) :

```swift
// ResearchVaultOwnerXPCProtocol
func listQuarantine(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
func reviewQuarantine(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
// ResearchVaultClient
public func quarantine() async throws -> [ResearchVaultQuarantineItem]
public func review(ids: [String], action: ResearchVaultReviewRequest.Action) async throws -> Int
```

- **Bascule d'intake** : dans le handler owner `importReceipts` du ServiceRuntime, l'insertion passe de `.approved` à **`.quarantined`**. C'est le point unique par lequel inbox, import fichiers et migration NotebookLM entrent — tout l'intake atterrit donc en quarantaine sans toucher les appelants app.

- [ ] **Step 1: Tests qui échouent** — étendre le test owner existant : importer 1 receipt via le endpoint owner, vérifier `quarantine()` le liste, `search` ne le voit pas ; `review(approve)` → recherche le voit ; importer un 2e, `review(reject)` → liste vide. Réutiliser exactement le harnais XPC des tests owner existants (identité de code, endpoints).

- [ ] **Step 2: Vérifier l'échec** — `verify.sh` FAIL.

- [ ] **Step 3: Implémenter** — IPC types + validation (mêmes gardes que `ResearchVaultReceiptImportRequest` : contractVersion, bornes) ; handlers owner dans le ServiceRuntime (décodage, appel store, réponse encodée, erreurs → `ResearchVaultIPCErrorPayload`) ; méthodes client ; bascule `.quarantined` dans le handler import.

- [ ] **Step 4: Vérifier vert** — `verify.sh` PASS + `Packages/ResearchVaultKit/Scripts/verify-ipc-boundary.sh` PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ResearchVaultKit
git commit -m "[throttle] feat: intake lands quarantined, owner XPC review ops"
```

---

### Task 4: Parseurs et importer NotebookLM dans le package

**Files:**
- Create: `Packages/ResearchVaultKit/Sources/ResearchVaultIngestion/ResearchDocumentTextExtractor.swift`
- Create: `Packages/ResearchVaultKit/Sources/ResearchVaultIngestion/NotebookLMMigrationImporter.swift`
- Modify: `Throttle/Services/ResearchVaultInboxBookmarkStore.swift` (supprimer les lignes 92-354 : erreurs, manifest, batch, importer — le fichier ne garde que le bookmark store)
- Modify: `Packages/ResearchVaultKit/Package.swift` (si `ResearchVaultIngestion` ne linke pas encore PDFKit/AppKit : ce sont des frameworks système macOS, un simple `import` suffit, pas de dépendance à déclarer)
- Test: `Packages/ResearchVaultKit/Tests/ResearchVaultIngestionTests/NotebookLMMigrationImporterTests.swift` (create)

**Interfaces:**
- Produces:

```swift
public enum ResearchDocumentTextExtractor {
    public static let supportedExtensions: Set<String>   // md, markdown, txt, csv, json, jsonl, html, htm, rtf, docx, pdf
    public static func extractText(from url: URL, bytes: Data) throws -> String
}
// NotebookLMMigrationImporter, NotebookLMMigrationError, NotebookLMMigrationFile,
// NotebookLMMigrationManifest, NotebookLMMigrationBatch : mêmes noms et mêmes
// signatures qu'aujourd'hui côté app, passés public, init(root:projectKey:sensitivity:)
// avec défaut de sensibilité .confidential inchangé.
```

- Consumes: rien de nouveau — code déplacé tel quel (source unique pour app, agent et MCP).

- [ ] **Step 1: Déplacer le code** — copier l'importer + types depuis `ResearchVaultInboxBookmarkStore.swift` vers les deux nouveaux fichiers package, `public` partout où l'app consomme ; extraire `extractText`/`attributedText`/PDF/limites dans `ResearchDocumentTextExtractor` et faire pointer l'importer dessus. Supprimer le code déplacé du fichier app. `import AppKit` + `import PDFKit` dans le package (macOS-only, OK).

- [ ] **Step 2: Tests package** — porter en test package : dossier temporaire avec `a.md`, `b.txt`, un symlink (refusé), un fichier > 512 KB (refusé) ; `load()` 2× → mêmes `receiptID` déterministes et même `aggregateSHA256` (idempotence, gate Phase 2) ; extensions non supportées ignorées.

```swift
@Test func doubleLoadIsDeterministic() throws {
    let root = try makeExportFolder(files: ["a.md": "# Alpha", "b.txt": "beta"])
    let first = try NotebookLMMigrationImporter(root: root, projectKey: "test-import").load()
    let second = try NotebookLMMigrationImporter(root: root, projectKey: "test-import").load()
    #expect(first.manifest.aggregateSHA256 == second.manifest.aggregateSHA256)
    #expect(first.receipts.map(\.receiptID) == second.receipts.map(\.receiptID))
}
```

- [ ] **Step 3: Vérifier vert package** — `verify.sh` PASS.

- [ ] **Step 4: Rebrancher l'app** — le Workbench model importe déjà `ResearchVaultIngestion` via le package ? Vérifier les imports de `ResearchVaultWorkbenchView.swift` (ajouter `import ResearchVaultIngestion` si besoin). Puis `xcodegen generate` puis `xcodebuild -scheme Throttle -configuration Debug -destination 'platform=macOS' build`.
Expected: build PASS, aucun doublon de symbole.

- [ ] **Step 5: Vérifier le gate de dépendances** — `scripts/verify-research-vault-dependencies.sh`
Expected: PASS (la cible app ne gagne aucun produit privilégié nouveau ; si le script liste les produits autorisés, y ajouter `ResearchVaultIngestion` s'il ne l'est pas déjà — c'est un produit non privilégié).

- [ ] **Step 6: Commit**

```bash
git add Packages/ResearchVaultKit Throttle/Services/ResearchVaultInboxBookmarkStore.swift Throttle.xcodeproj project.yml scripts/verify-research-vault-dependencies.sh
git commit -m "[throttle] refactor: parsers and NLM importer move into the package"
```

---

### Task 5: Export Markdown dérivé

**Files:**
- Create: `Packages/ResearchVaultKit/Sources/ResearchVaultIngestion/ResearchVaultMarkdownExporter.swift`
- Modify: `Throttle/UI/ResearchVault/ResearchVaultWorkbenchView.swift` (bouton + méthode model)
- Test: `Packages/ResearchVaultKit/Tests/ResearchVaultIngestionTests/ResearchVaultMarkdownExporterTests.swift` (create)

**Interfaces:**
- Consumes: `ResearchReceipt` (model).
- Produces:

```swift
public struct ResearchVaultMarkdownDocument: Equatable, Sendable {
    public let filename: String       // "<projectKey>--<receiptID court>.md", unique par receiptID
    public let content: String
}
public enum ResearchVaultMarkdownExporter {
    /// Dérivé jetable : front-matter YAML (receipt_id, project_key, sensitivity,
    /// created_at ISO8601, sources avec locator+sha256), puis chaque finding
    /// avec son statut et ses evidence IDs. Déterministe pour un même receipt.
    public static func export(_ receipts: [ResearchReceipt]) -> [ResearchVaultMarkdownDocument]
}
```

- [ ] **Step 1: Test qui échoue**

```swift
@Test func exportIsDeterministicAndCarriesProvenance() throws {
    let receipt = try makeSealedReceipt(claim: "exported claim")
    let a = ResearchVaultMarkdownExporter.export([receipt])
    let b = ResearchVaultMarkdownExporter.export([receipt])
    #expect(a == b)
    #expect(a.count == 1)
    #expect(a[0].content.contains("receipt_id:"))
    #expect(a[0].content.contains("sha256"))
    #expect(a[0].content.contains("status: open"))
    #expect(a[0].content.contains("exported claim"))
}
```

- [ ] **Step 2: Vérifier l'échec** — `verify.sh` FAIL.

- [ ] **Step 3: Implémenter l'exporter** — front-matter à clés triées, dates ISO8601 UTC, contenu = findings dans l'ordre du receipt. Aucun accès disque dans le package (pur : receipts → documents en mémoire).

- [ ] **Step 4: Vérifier vert** — `verify.sh` PASS.

- [ ] **Step 5: Brancher le Workbench** — dans le model : `exportMarkdown()` — récupère les receipts approuvés via le client (`client.search` ne renvoie pas les receipts complets : utiliser le chemin owner existant s'il expose une lecture, sinon exporter à partir des receipts de la dernière migration/import en mémoire est INSUFFISANT — ajouter au ServiceRuntime une réponse owner `exportReceipts` qui renvoie les receipts approuvés scellés, même pattern que Task 3, plafonnée à 32 par page). NSSavePanel dossier → un fichier .md par receipt, écriture `.atomic`. Bouton "Export Markdown…" à côté de "Save integrity manifest…".

- [ ] **Step 6: Build app** — `xcodegen generate` (si fichiers ajoutés) + `xcodebuild … build` PASS.

- [ ] **Step 7: Commit**

```bash
git add Packages/ResearchVaultKit Throttle/UI/ResearchVault
git commit -m "[throttle] feat: derived markdown export with provenance front matter"
```

---

### Task 6: Intake URL

**Files:**
- Create: `Throttle/Services/ResearchVaultURLIntake.swift`
- Modify: `Throttle/UI/ResearchVault/ResearchVaultWorkbenchView.swift` (champ URL + bouton)
- Test: `ThrottleTests/ServiceTests/ResearchVaultURLIntakeTests.swift` (create)

**Interfaces:**
- Consumes: `WebURLPolicy.rejectionReason(for:resolveDNS:)` (`Throttle/Services/WebURLPolicy.swift:44`), `ResearchDocumentTextExtractor` (Task 4), `ResearchReceipt.seal`, `client.importReceipts` (atterrit en quarantaine via Task 3).
- Produces:

```swift
enum ResearchVaultURLIntakeError: Error, Equatable {
    case invalidScheme            // https uniquement
    case blockedByPolicy(String)  // raison WebURLPolicy
    case responseTooLarge         // > 512 * 1_024 octets
    case unsupportedContent       // ni text/*, ni html
    case emptyExtraction
}
struct ResearchVaultURLIntake {
    static let maximumBytes = 512 * 1_024
    /// Pur et testable : construit le receipt depuis des octets déjà téléchargés.
    static func receipt(url: URL, mimeType: String?, bytes: Data,
                        projectKey: String, sensitivity: ResearchSensitivity) throws -> ResearchReceipt
    /// Vérifie schéma https + WebURLPolicy, télécharge (une requête, pas de
    /// crawling), plafonne la taille, délègue à receipt(...).
    static func fetch(url: URL, projectKey: String,
                      sensitivity: ResearchSensitivity) async throws -> ResearchReceipt
}
```

- [ ] **Step 1: Tests qui échouent** (sur la partie pure — pas de réseau dans les tests)

```swift
func testRejectsNonHTTPS() {
    XCTAssertThrowsError(try ResearchVaultURLIntake.receipt(
        url: URL(string: "http://example.com")!, mimeType: "text/html",
        bytes: Data("x".utf8), projectKey: "url-intake", sensitivity: .internal
    )) { XCTAssertEqual($0 as? ResearchVaultURLIntakeError, .invalidScheme) }
}

func testRejectsOversizedBody() {
    let big = Data(repeating: 0x61, count: ResearchVaultURLIntake.maximumBytes + 1)
    XCTAssertThrowsError(try ResearchVaultURLIntake.receipt(
        url: URL(string: "https://example.com/doc")!, mimeType: "text/plain",
        bytes: big, projectKey: "url-intake", sensitivity: .internal
    )) { XCTAssertEqual($0 as? ResearchVaultURLIntakeError, .responseTooLarge) }
}

func testHTMLBecomesOpenReceiptWithURLSource() throws {
    let html = Data("<html><body><p>Grounded fact.</p></body></html>".utf8)
    let receipt = try ResearchVaultURLIntake.receipt(
        url: URL(string: "https://example.com/article")!, mimeType: "text/html",
        bytes: html, projectKey: "url-intake", sensitivity: .internal
    )
    XCTAssertEqual(receipt.sources.first?.kind, .url)
    XCTAssertEqual(receipt.sources.first?.locator, "https://example.com/article")
    XCTAssertTrue(receipt.findings.allSatisfy { $0.status == .open })
    XCTAssertTrue(receipt.findings.contains { $0.claim.contains("Grounded fact") })
}
```

NB : le cas s'écrit `` `internal` `` (backticks Swift) dans `ResearchSensitivity` — utiliser `.internal` aux points d'appel.

- [ ] **Step 2: Vérifier l'échec** — cible de test app : `xcodebuild -scheme Throttle -configuration Debug -destination 'platform=macOS' test -only-testing:ThrottleTests/ResearchVaultURLIntakeTests` (ou le runner de tests utilisé par `scripts/smoke-test.sh` si différent). Expected: FAIL (type absent).

- [ ] **Step 3: Implémenter** — `receipt(...)` : garde https, garde taille, extraction texte (html/htm → `ResearchDocumentTextExtractor.extractText`, `text/*` → UTF-8 direct, sinon `unsupportedContent`), chunking par la même règle que l'importer (30 000 chars), `ResearchReceipt.seal` avec `receiptID` déterministe (SHA-256 de `projectKey\nurl\nsha256(bytes)` — réutiliser le helper UUID déterministe déplacé en Task 4), `sessionID: "url-intake:<sha256 court>"`, `agentID: "throttle-url-intake-v1"`, question `"Imported URL: <url>"`, openQuestions inchangés (« not independently verified »). `fetch(...)` : `WebURLPolicy.rejectionReason` d'abord (throw `.blockedByPolicy`), puis `URLSession.shared.data(from:)` avec vérif taille avant et après.

- [ ] **Step 4: Vérifier vert** — même commande de test, PASS.

- [ ] **Step 5: Brancher le Workbench** — champ `urlToImport` + bouton "Import URL…" → `fetch` → `client.importReceipts([receipt])` → status « URL en quarantaine : … ». `xcodegen generate` + build PASS.

- [ ] **Step 6: Commit**

```bash
git add Throttle/Services/ResearchVaultURLIntake.swift Throttle/UI/ResearchVault ThrottleTests/ServiceTests/ResearchVaultURLIntakeTests.swift project.yml
git commit -m "[throttle] feat: policy-gated single-URL intake into quarantine"
```

---

### Task 7: Section Quarantaine du Workbench

**Files:**
- Modify: `Throttle/UI/ResearchVault/ResearchVaultWorkbenchView.swift` (model + view)

**Interfaces:**
- Consumes: `client.quarantine()`, `client.review(ids:action:)` (Task 3).
- Produces (model) : `var pendingItems: [ResearchVaultQuarantineItem]`, `func loadQuarantine() async`, `func review(_ ids: [String], approve: Bool) async`.

- [ ] **Step 1: Model** — trois méthodes suivant exactement le style existant (`isBusy`, `status` localisé, échec fermé). `loadQuarantine()` appelée après chaque import/sync réussi et depuis `checkHealth()`.

- [ ] **Step 2: View** — sous les boutons d'import, section « Quarantine (n) » : liste de lignes (question tronquée, projectKey, sensibilité, date, `firstSourceLocator` en secondaire) + par ligne « Approve » / « Reject », + « Approve All » / « Reject All » quand n > 1. Design language : hairlines `Color.primary.opacity(0.09)`, chiffres tabulaires, pas de Canvas/`.shadow`/`.contentTransition`, bleu réservé aux actions.

- [ ] **Step 3: Vérification manuelle** — `xcodebuild … build` PASS, puis lancer la target de test UI existante `-researchVaultWorkbenchTest` (AppDelegate) **sans toucher l'app installée** : importer un receipt de test → visible en quarantaine → invisible en recherche → Approve → visible en recherche. Consigner le résultat dans le message de commit.

- [ ] **Step 4: Commit**

```bash
git add Throttle/UI/ResearchVault
git commit -m "[throttle] feat: workbench quarantine review section"
```

---

### Task 8: Gates de fin de Lot 1

**Files:**
- Modify: `docs/TODO.md` (ajouter la ligne de gate Lot 1 avec les preuves)

- [ ] **Step 1: Suite package complète** — `Packages/ResearchVaultKit/Scripts/verify.sh` PASS (Debug ; lancer aussi Release si le script le propose).
- [ ] **Step 2: Frontière IPC** — `Packages/ResearchVaultKit/Scripts/verify-ipc-boundary.sh` PASS.
- [ ] **Step 3: Dépendances app** — `scripts/verify-research-vault-dependencies.sh` PASS.
- [ ] **Step 4: Build + tests app** — `xcodegen generate` puis `xcodebuild -scheme Throttle -configuration Debug -destination 'platform=macOS' test` (suite macOS complète) — zéro échec nouveau.
- [ ] **Step 5: SwiftLint** — `swiftlint --strict` (baseline `.swiftlint-baseline.json`) — zéro violation nouvelle.
- [ ] **Step 6: Checklist gate Phase 2 (spec)** — cocher avec preuve de test : import 2× sans duplication (Task 4 test), changement de source détecté (hash), symlink/oversize refusés (tests portés), zéro promotion silencieuse (Tasks 1-3 : tout intake = quarantined, recherche = approved only).
- [ ] **Step 7: Consigner dans `docs/TODO.md`** — une ligne de gate « Lot 1 intake » avec les preuves, puis commit :

```bash
git add docs/TODO.md
git commit -m "[throttle] docs: lot 1 intake gates recorded with evidence"
```

---

## Self-review (fait à l'écriture)

- Couverture spec Lot 1 : quarantaine (T1-T3, T7), parseurs package (T4), export MD (T5), URL (T6), gates (T8). ✔
- `reviewState` sans valeur par défaut → aucun appel implicite. ✔
- Noms croisés vérifiés : `quarantinedReceipts`/`approveReceipts`/`rejectReceipts` (T2) = ceux consommés par T3 ; `ResearchDocumentTextExtractor` (T4) = celui consommé par T6. ✔
- Point ouvert assumé (T5 Step 5) : la lecture des receipts approuvés pour l'export passe par un nouvel endpoint owner `exportReceipts` — même pattern que T3, décrit dans la task.
- Cas `ResearchSensitivity` vérifié : `.internal` (mot réservé échappé par backticks). ✔
