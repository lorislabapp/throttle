import Foundation

/// Command line of the benchmark: one corpus root, at most one reference
/// (source-pinned hash, frozen manifest or a new freeze) and optional human questions.
struct BenchmarkOptions {
    enum Reference { case sourcePinned, manifest(URL), freeze(URL) }
    struct ParseError: Error, CustomStringConvertible { let description: String }

    let root: URL
    let reference: Reference
    let humanQueries: URL?

    static func parse(_ arguments: [String]) throws -> BenchmarkOptions {
        var root: URL?
        var reference = Reference.sourcePinned
        var human: URL?
        var index = 0
        func value(_ flag: String) throws -> URL {
            index += 1
            guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                throw ParseError(description: flag + " requires a path")
            }
            return URL(fileURLWithPath: arguments[index])
        }
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let path = try value(argument)
                switch argument {
                case "--manifest", "--freeze":
                    guard case .sourcePinned = reference else { throw ParseError(description: "one reference only") }
                    reference = argument == "--manifest" ? .manifest(path) : .freeze(path)
                case "--human-queries":
                    guard human == nil else { throw ParseError(description: "one human query set only") }
                    human = path
                default:
                    throw ParseError(description: "unknown option " + argument)
                }
            } else {
                guard root == nil else { throw ParseError(description: "one corpus root only") }
                root = URL(fileURLWithPath: argument)
            }
            index += 1
        }
        guard let root else { throw ParseError(description: "missing corpus root") }
        return BenchmarkOptions(root: root, reference: reference, humanQueries: human)
    }
}
