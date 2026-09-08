extension SQLCipherSchema {
    static let version1: [String] = [
        """
        CREATE TABLE receipts(
            receipt_id TEXT PRIMARY KEY NOT NULL,
            project_key TEXT NOT NULL,
            sensitivity TEXT NOT NULL,
            sensitivity_rank INTEGER NOT NULL CHECK(sensitivity_rank BETWEEN 0 AND 3),
            created_at_ms INTEGER NOT NULL,
            content_hash TEXT NOT NULL UNIQUE CHECK(length(content_hash) = 64),
            payload BLOB NOT NULL
        );
        """,
        """
        CREATE TABLE sources(
            receipt_id TEXT NOT NULL REFERENCES receipts(receipt_id) ON DELETE CASCADE,
            source_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            locator TEXT NOT NULL,
            observed_at_ms INTEGER NOT NULL,
            plaintext_sha256 TEXT NOT NULL CHECK(length(plaintext_sha256) = 64),
            PRIMARY KEY(receipt_id, source_id)
        ) WITHOUT ROWID;
        """,
        """
        CREATE TABLE findings(
            id INTEGER PRIMARY KEY,
            receipt_id TEXT NOT NULL REFERENCES receipts(receipt_id) ON DELETE CASCADE,
            claim TEXT NOT NULL,
            status TEXT NOT NULL
        );
        """,
        """
        CREATE TABLE finding_evidence(
            finding_id INTEGER NOT NULL REFERENCES findings(id) ON DELETE CASCADE,
            receipt_id TEXT NOT NULL,
            source_id TEXT NOT NULL,
            PRIMARY KEY(finding_id, source_id),
            FOREIGN KEY(receipt_id, source_id)
                REFERENCES sources(receipt_id, source_id) ON DELETE CASCADE
        ) WITHOUT ROWID;
        """,
        """
        CREATE VIRTUAL TABLE finding_fts USING fts5(
            claim,
            content='findings',
            content_rowid='id',
            tokenize='unicode61 remove_diacritics 2'
        );
        """,
        """
        CREATE TRIGGER findings_after_insert AFTER INSERT ON findings BEGIN
            INSERT INTO finding_fts(rowid, claim) VALUES (new.id, new.claim);
        END;
        """,
        """
        CREATE TRIGGER findings_after_delete AFTER DELETE ON findings BEGIN
            INSERT INTO finding_fts(finding_fts, rowid, claim)
            VALUES ('delete', old.id, old.claim);
        END;
        """,
        """
        CREATE TRIGGER findings_after_update AFTER UPDATE ON findings BEGIN
            INSERT INTO finding_fts(finding_fts, rowid, claim)
            VALUES ('delete', old.id, old.claim);
            INSERT INTO finding_fts(rowid, claim) VALUES (new.id, new.claim);
        END;
        """,
        "CREATE INDEX receipts_scope ON receipts(project_key, sensitivity_rank, created_at_ms);",
        "CREATE INDEX findings_receipt ON findings(receipt_id);"
    ]
}
