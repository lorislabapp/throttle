import Foundation

/// Compatibility boundary for saved conversations. Shell text is not a
/// read-only capability: git/find and their options can execute or mutate.
/// Execution requires a separately authorized, typed effect boundary.
enum BashSandbox {
    static func run(command: String) -> String {
        "Error: generic shell execution is disabled. Use project read_file, list_files or search_files."
    }
}
