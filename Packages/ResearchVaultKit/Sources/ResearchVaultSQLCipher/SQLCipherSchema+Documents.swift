extension SQLCipherSchema {
    static let version2: [String] = [
        """
        CREATE TABLE documents(
            document_id TEXT PRIMARY KEY NOT NULL,
            project_key TEXT NOT NULL,
            sensitivity TEXT NOT NULL,
            sensitivity_rank INTEGER NOT NULL CHECK(sensitivity_rank BETWEEN 0 AND 3),
            title TEXT NOT NULL,
            category TEXT NOT NULL,
            library_path TEXT NOT NULL,
            origins_json BLOB NOT NULL,
            content TEXT NOT NULL,
            plaintext_sha256 TEXT NOT NULL CHECK(length(plaintext_sha256) = 64),
            byte_count INTEGER NOT NULL CHECK(byte_count >= 0),
            modified_at_ms INTEGER NOT NULL
        );
        """,
        """
        CREATE TABLE document_chunks(
            id INTEGER PRIMARY KEY,
            document_id TEXT NOT NULL REFERENCES documents(document_id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
            title TEXT NOT NULL,
            heading TEXT,
            content TEXT NOT NULL,
            approximate_token_count INTEGER NOT NULL CHECK(approximate_token_count > 0),
            UNIQUE(document_id, ordinal)
        );
        """,
        """
        CREATE VIRTUAL TABLE document_chunk_fts USING fts5(
            title, heading, content,
            content='document_chunks', content_rowid='id',
            tokenize='unicode61 remove_diacritics 2'
        );
        """,
        """
        CREATE TRIGGER document_chunks_after_insert AFTER INSERT ON document_chunks BEGIN
            INSERT INTO document_chunk_fts(rowid, title, heading, content)
            VALUES (new.id, new.title, new.heading, new.content);
        END;
        """,
        """
        CREATE TRIGGER document_chunks_after_delete AFTER DELETE ON document_chunks BEGIN
            INSERT INTO document_chunk_fts(document_chunk_fts, rowid, title, heading, content)
            VALUES ('delete', old.id, old.title, old.heading, old.content);
        END;
        """,
        """
        CREATE TRIGGER document_chunks_after_update AFTER UPDATE ON document_chunks BEGIN
            INSERT INTO document_chunk_fts(document_chunk_fts, rowid, title, heading, content)
            VALUES ('delete', old.id, old.title, old.heading, old.content);
            INSERT INTO document_chunk_fts(rowid, title, heading, content)
            VALUES (new.id, new.title, new.heading, new.content);
        END;
        """,
        "CREATE INDEX documents_scope ON documents(project_key, sensitivity_rank, modified_at_ms);",
        "CREATE INDEX document_chunks_document ON document_chunks(document_id, ordinal);"
    ]
    static let version3: [String] = [
        "ALTER TABLE documents ADD COLUMN observed_at_ms INTEGER NOT NULL DEFAULT 0;",
        "UPDATE documents SET observed_at_ms = modified_at_ms WHERE observed_at_ms = 0;",
        "ALTER TABLE documents ADD COLUMN evidence_status TEXT;",
        """
        CREATE TABLE retrieval_state(
            name TEXT PRIMARY KEY NOT NULL,
            generation INTEGER NOT NULL CHECK(generation >= 0)
        ) WITHOUT ROWID;
        """,
        """
        INSERT INTO retrieval_state(name, generation)
        VALUES ('document-fts', (SELECT count(*) FROM documents));
        """,
        """
        CREATE TRIGGER documents_generation_after_insert
        AFTER INSERT ON documents BEGIN
            UPDATE retrieval_state SET generation = generation + 1
            WHERE name = 'document-fts';
        END;
        """,
        """
        CREATE TRIGGER documents_generation_after_delete
        AFTER DELETE ON documents BEGIN
            UPDATE retrieval_state SET generation = generation + 1
            WHERE name = 'document-fts';
        END;
        """
    ]
    static let version4: [String] = [
        """
        ALTER TABLE receipts ADD COLUMN review_state TEXT NOT NULL DEFAULT 'approved' \
        CHECK(review_state IN ('quarantined','approved'));
        """,
        """
        ALTER TABLE documents ADD COLUMN review_state TEXT NOT NULL DEFAULT 'approved' \
        CHECK(review_state IN ('quarantined','approved'));
        """,
        "CREATE INDEX receipts_review ON receipts(review_state, project_key);",
        "CREATE INDEX documents_review ON documents(review_state, project_key);"
    ]
}
