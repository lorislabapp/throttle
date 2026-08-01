import CryptoKit
import Darwin
import Foundation

public enum GoliathControlPlane {
    public static let receiptVersion = "goliath.control-plane.receipt.v1"

    public struct Receipt: Codable, Equatable, Sendable {
        public let kind: String
        public let contractVersion: String
        public let actionId: String
        public let traceparent: String
        public let sequence: UInt64
        public let component: String
        public let decision: String
        public let inputBytes: UInt64
        public let outputBytes: UInt64
        public let estimatedTokensBefore: UInt64
        public let estimatedTokensAfter: UInt64
        public let artifactSha256: String?
        public let eventSha256: String

        public init(
            actionId: String, traceparent: String, sequence: UInt64,
            component: String, decision: String, inputBytes: UInt64, outputBytes: UInt64,
            estimatedTokensBefore: UInt64, estimatedTokensAfter: UInt64,
            artifactSha256: String?, eventSha256: String
        ) {
            self.kind = "receipt"
            self.contractVersion = GoliathControlPlane.receiptVersion
            self.actionId = actionId
            self.traceparent = traceparent
            self.sequence = sequence
            self.component = component
            self.decision = decision
            self.inputBytes = inputBytes
            self.outputBytes = outputBytes
            self.estimatedTokensBefore = estimatedTokensBefore
            self.estimatedTokensAfter = estimatedTokensAfter
            self.artifactSha256 = artifactSha256
            self.eventSha256 = eventSha256
        }

        public func validate() throws {
            guard kind == "receipt", contractVersion == GoliathControlPlane.receiptVersion,
                  sequence > 0, ["super-orchestrateur", "supergateway", "throttle"].contains(component),
                  ["allowed", "denied", "error"].contains(decision),
                  Self.validTraceparent(traceparent), Self.validSha256(eventSha256),
                  artifactSha256.map(Self.validSha256) ?? true else {
                throw ContractError.invalidReceipt
            }
            guard eventSha256 == Self.eventHash(self) else { throw ContractError.hashMismatch }
        }

        public static func eventHash(
            actionId: String, traceparent: String, sequence: UInt64,
            component: String, decision: String, inputBytes: UInt64, outputBytes: UInt64,
            estimatedTokensBefore: UInt64, estimatedTokensAfter: UInt64,
            artifactSha256: String?
        ) -> String {
            let values = [
                GoliathControlPlane.receiptVersion, actionId, traceparent, String(sequence),
                component, decision, String(inputBytes), String(outputBytes),
                String(estimatedTokensBefore), String(estimatedTokensAfter), artifactSha256 ?? "null"
            ]
            let framed = values.map { "\($0.utf8.count):\($0)" }.joined()
            return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        private static func eventHash(_ receipt: Receipt) -> String {
            eventHash(
                actionId: receipt.actionId, traceparent: receipt.traceparent, sequence: receipt.sequence,
                component: receipt.component, decision: receipt.decision,
                inputBytes: receipt.inputBytes, outputBytes: receipt.outputBytes,
                estimatedTokensBefore: receipt.estimatedTokensBefore,
                estimatedTokensAfter: receipt.estimatedTokensAfter,
                artifactSha256: receipt.artifactSha256)
        }

        private static func validTraceparent(_ value: String) -> Bool {
            value.range(of: #"^00-[0-9a-f]{32}-[0-9a-f]{16}-0[01]$"#,
                        options: .regularExpression) != nil
        }

        private static func validSha256(_ value: String) -> Bool {
            value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        }
    }

    public enum ContractError: Error, Equatable { case invalidReceipt, hashMismatch }

    public struct AccountingSnapshot: Equatable, Sendable {
        public let acceptedEvents: Int
        public let inputBytes: UInt64
        public let outputBytes: UInt64
        public let estimatedTokensBefore: UInt64
        public let estimatedTokensAfter: UInt64

        public var estimatedTokensSaved: UInt64 {
            estimatedTokensBefore > estimatedTokensAfter
                ? estimatedTokensBefore - estimatedTokensAfter : 0
        }
    }

    public struct AccountingLedger: Sendable {
        private var eventHashes = Set<String>()
        private var acceptedEvents = 0
        private var inputBytes: UInt64 = 0
        private var outputBytes: UInt64 = 0
        private var tokensBefore: UInt64 = 0
        private var tokensAfter: UInt64 = 0

        public init() {}

        @discardableResult
        public mutating func consume(_ receipt: Receipt) throws -> Bool {
            try receipt.validate()
            guard eventHashes.insert(receipt.eventSha256).inserted else { return false }
            acceptedEvents += 1
            inputBytes += receipt.inputBytes
            outputBytes += receipt.outputBytes
            tokensBefore += receipt.estimatedTokensBefore
            tokensAfter += receipt.estimatedTokensAfter
            return true
        }

        public var snapshot: AccountingSnapshot {
            AccountingSnapshot(
                acceptedEvents: acceptedEvents, inputBytes: inputBytes, outputBytes: outputBytes,
                estimatedTokensBefore: tokensBefore, estimatedTokensAfter: tokensAfter)
        }
    }

    public struct DurableConsumeResult: Equatable, Sendable {
        public let inserted: Bool
        public let snapshot: AccountingSnapshot
    }

    public struct DurableAccountingStore: Sendable {
        private struct State: Codable {
            var eventHashes = Set<String>()
            var acceptedEvents = 0
            var inputBytes: UInt64 = 0
            var outputBytes: UInt64 = 0
            var tokensBefore: UInt64 = 0
            var tokensAfter: UInt64 = 0
        }

        private let fileURL: URL

        public init(fileURL: URL) { self.fileURL = fileURL }

        public func consume(_ receipt: Receipt) throws -> DurableConsumeResult {
            try receipt.validate()
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let lockURL = fileURL.appendingPathExtension("lock")
            let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileLocking) }
            defer { flock(descriptor, LOCK_UN) }

            var state = try load()
            let inserted = state.eventHashes.insert(receipt.eventSha256).inserted
            if inserted {
                state.acceptedEvents += 1
                state.inputBytes += receipt.inputBytes
                state.outputBytes += receipt.outputBytes
                state.tokensBefore += receipt.estimatedTokensBefore
                state.tokensAfter += receipt.estimatedTokensAfter
                let data = try JSONEncoder().encode(state)
                // Receipts contain accounting metadata, not credentials. On macOS 27,
                // completeFileProtection makes Foundation's atomic temporary-file
                // creation fail with EPERM outside a data-protection container. Keep
                // crash-safe replacement and enforce private POSIX permissions below.
                try data.write(to: fileURL, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
            return DurableConsumeResult(inserted: inserted, snapshot: snapshot(state))
        }

        private func load() throws -> State {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return State() }
            return try JSONDecoder().decode(State.self, from: Data(contentsOf: fileURL))
        }

        private func snapshot(_ state: State) -> AccountingSnapshot {
            AccountingSnapshot(
                acceptedEvents: state.acceptedEvents, inputBytes: state.inputBytes,
                outputBytes: state.outputBytes, estimatedTokensBefore: state.tokensBefore,
                estimatedTokensAfter: state.tokensAfter)
        }
    }
}
