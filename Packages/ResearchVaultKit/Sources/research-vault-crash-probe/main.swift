import Foundation
@_spi(Testing) import ResearchVaultSQLCipher

private let testKey = Data(repeating: 0xc7, count: 32)

@main
struct ResearchVaultCrashProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw ProbeError.invalidArguments
        }
        let mode = CommandLine.arguments[1]
        let database = URL(fileURLWithPath: CommandLine.arguments[2])

        switch mode {
        case "prepare-write":
            try SQLCipherRuntime.prepareWriteCrashProbe(databaseURL: database, key: testKey)
            print("{\"status\":\"prepared-write\"}")
        case "crash-write":
            try SQLCipherRuntime.terminateDuringWriteProbe(databaseURL: database, key: testKey)
        case "verify-write":
            let evidence = try SQLCipherRuntime.verifyWriteCrashProbe(
                databaseURL: database,
                key: testKey
            )
            print(
                "{\"status\":\"pass\",\"scenario\":\"write\",\"rows\":"
                    + String(evidence.committedRowCount) + "}"
            )
        case "prepare-migration":
            try SQLCipherRuntime.prepareMigrationCrashProbe(databaseURL: database, key: testKey)
            print("{\"status\":\"prepared-migration\"}")
        case "crash-migration":
            try SQLCipherRuntime.terminateDuringMigrationProbe(databaseURL: database, key: testKey)
        case "verify-migration":
            let evidence = try SQLCipherRuntime.verifyMigrationCrashProbe(
                databaseURL: database,
                key: testKey
            )
            print(
                "{\"status\":\"pass\",\"scenario\":\"migration\",\"schemaVersion\":"
                    + String(evidence.schemaVersion) + "}"
            )
        default:
            throw ProbeError.invalidArguments
        }
    }
}

private enum ProbeError: Error {
    case invalidArguments
}

