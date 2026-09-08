extension SQLCipherSchema {
    static let version6: [String] = [
        """
        CREATE TABLE spaces(
            space_id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            kind TEXT NOT NULL CHECK(kind IN ('portfolio','project')),
            created_at_ms INTEGER NOT NULL
        ) WITHOUT ROWID;
        """,
        """
        CREATE TABLE space_project_keys(
            space_id TEXT NOT NULL REFERENCES spaces(space_id) ON DELETE CASCADE,
            project_key TEXT NOT NULL,
            PRIMARY KEY(space_id, project_key)
        ) WITHOUT ROWID;
        """,
        "INSERT INTO spaces(space_id, name, kind, created_at_ms) VALUES ('portfolio', 'Portfolio', 'portfolio', 0);",
        """
        INSERT OR IGNORE INTO spaces(space_id, name, kind, created_at_ms)
        SELECT 'project:' || project_key, project_key, 'project', 0
        FROM (
            SELECT project_key FROM receipts
            UNION SELECT project_key FROM documents
            UNION SELECT project_key FROM reasoning_base_facts
        );
        """,
        """
        INSERT OR IGNORE INTO space_project_keys(space_id, project_key)
        SELECT 'project:' || project_key, project_key
        FROM (
            SELECT project_key FROM receipts
            UNION SELECT project_key FROM documents
            UNION SELECT project_key FROM reasoning_base_facts
        );
        """,
        """
        INSERT OR IGNORE INTO space_project_keys(space_id, project_key)
        SELECT 'portfolio', project_key
        FROM (
            SELECT project_key FROM receipts
            UNION SELECT project_key FROM documents
            UNION SELECT project_key FROM reasoning_base_facts
        );
        """,
        "CREATE INDEX space_project_lookup ON space_project_keys(project_key, space_id);",
        """
        CREATE TRIGGER spaces_after_receipt_insert AFTER INSERT ON receipts BEGIN
            INSERT OR IGNORE INTO spaces(space_id, name, kind, created_at_ms)
            VALUES ('project:' || new.project_key, new.project_key, 'project', new.created_at_ms);
            INSERT OR IGNORE INTO space_project_keys(space_id, project_key)
            VALUES ('project:' || new.project_key, new.project_key);
            INSERT OR IGNORE INTO space_project_keys(space_id, project_key)
            VALUES ('portfolio', new.project_key);
        END;
        """,
        """
        CREATE TRIGGER spaces_after_document_insert AFTER INSERT ON documents BEGIN
            INSERT OR IGNORE INTO spaces(space_id, name, kind, created_at_ms)
            VALUES ('project:' || new.project_key, new.project_key, 'project', new.observed_at_ms);
            INSERT OR IGNORE INTO space_project_keys(space_id, project_key)
            VALUES ('project:' || new.project_key, new.project_key);
            INSERT OR IGNORE INTO space_project_keys(space_id, project_key)
            VALUES ('portfolio', new.project_key);
        END;
        """
    ]
}
