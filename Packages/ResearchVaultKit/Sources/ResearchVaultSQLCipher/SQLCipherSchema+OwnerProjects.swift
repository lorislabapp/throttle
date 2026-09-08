extension SQLCipherSchema {
    static let version7: [String] = [
        "CREATE TABLE owner_project_grants(project_key TEXT PRIMARY KEY NOT NULL);",
        "CREATE INDEX findings_receipt_order ON findings(receipt_id, id);"
    ]
}
