extension SQLCipherSchema {
    static let version5: [String] = [
        """
        CREATE TABLE reasoning_generations(
            name TEXT PRIMARY KEY NOT NULL,
            base_generation INTEGER NOT NULL CHECK(base_generation >= 0),
            rule_pack_hash TEXT NOT NULL,
            engine_version TEXT NOT NULL,
            rules_json BLOB NOT NULL
        ) WITHOUT ROWID;
        """,
        """
        INSERT INTO reasoning_generations(name, base_generation, rule_pack_hash, \
        engine_version, rules_json) VALUES ('active', 0, '', '', X'5b5d');
        """,
        """
        CREATE TABLE reasoning_base_facts(
            fact_id TEXT PRIMARY KEY NOT NULL CHECK(length(fact_id) = 64),
            project_key TEXT NOT NULL,
            predicate TEXT NOT NULL,
            sensitivity_rank INTEGER NOT NULL CHECK(sensitivity_rank BETWEEN 0 AND 3),
            payload BLOB NOT NULL
        );
        """,
        "CREATE INDEX reasoning_base_scope ON reasoning_base_facts(project_key, sensitivity_rank, predicate);",
        """
        CREATE TABLE reasoning_fact_evidence(
            fact_id TEXT NOT NULL REFERENCES reasoning_base_facts(fact_id) ON DELETE CASCADE,
            receipt_id TEXT NOT NULL,
            source_id TEXT NOT NULL,
            PRIMARY KEY(fact_id, receipt_id, source_id),
            FOREIGN KEY(receipt_id, source_id)
                REFERENCES sources(receipt_id, source_id) ON DELETE RESTRICT
        ) WITHOUT ROWID;
        """,
        """
        CREATE TABLE reasoning_derived_cache(
            fact_id TEXT PRIMARY KEY NOT NULL CHECK(length(fact_id) = 64),
            project_key TEXT NOT NULL,
            sensitivity_rank INTEGER NOT NULL CHECK(sensitivity_rank BETWEEN 0 AND 3),
            base_generation INTEGER NOT NULL CHECK(base_generation >= 0),
            rule_pack_hash TEXT NOT NULL CHECK(length(rule_pack_hash) = 64),
            engine_version TEXT NOT NULL,
            payload BLOB NOT NULL
        );
        """,
        "CREATE INDEX reasoning_cache_scope ON reasoning_derived_cache(project_key, sensitivity_rank);",
        """
        CREATE TABLE reasoning_derivations(
            conclusion_fact_id TEXT NOT NULL REFERENCES reasoning_derived_cache(fact_id) ON DELETE CASCADE,
            rule_id TEXT NOT NULL,
            premise_fact_ids_json BLOB NOT NULL,
            PRIMARY KEY(conclusion_fact_id, rule_id, premise_fact_ids_json)
        ) WITHOUT ROWID;
        """
    ]
}
