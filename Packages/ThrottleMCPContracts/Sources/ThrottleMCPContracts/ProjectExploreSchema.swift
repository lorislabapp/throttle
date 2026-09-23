import Foundation

extension ThrottleMCPSchemas {
    public static func projectExploreSchema() -> [String: Any] {
        [
            "name": "throttle_project_explore",
            "description": """
            Explore the current project through bounded, read-only list, exact
            search and read operations. Every response includes a receipt naming
            the files whose bytes were read, their hashes and the enforced limits.
            Use SQL or a typed service for aggregation and all mutations.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "project": ["type": "string", "description": "Absolute project root."],
                    "operation": ["type": "string", "enum": ["list", "search", "read"]],
                    "path": ["type": "string", "description": "Relative file or directory path."],
                    "query": ["type": "string", "description": "Exact text for search."],
                    "max_chars": [
                        "type": "integer",
                        "minimum": 1_000,
                        "maximum": 64_000
                    ]
                ],
                "required": ["operation"]
            ]
        ]
    }

}
