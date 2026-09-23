import Foundation

extension ClaudeWebSessionProvider {
    private struct PollProgress {
        var emittedLength = 0
        var pollsBeforeAnyText = 0
    }

    private enum PollOutcome {
        case pending
        case complete
        case failed(AIProviderError)
        case interrupted(String)
    }

    func streamResponses(pollJS: String, logSnapshot: String) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                var progress = PollProgress()
                // Recursive tool-result turns can take 30–50 s before
                // first token (claude.ai server-side digests the
                // tool_results, runs prompt-cache checks, then plans).
                // 60 s of total silence is a fairer "the stream really
                // dropped" signal — anything sooner caused false
                // positives where the model was just thinking hard.
                var totalPolls = 0
                let maxTotalPolls = 1200          // 3 min absolute cap
                var streamingError: String?
                pollLoop: while !Task.isCancelled {
                    totalPolls += 1
                    if totalPolls > maxTotalPolls {
                        streamingError = "stream still running after 3 min (\(logSnapshot))"
                        break pollLoop
                    }
                    do { try await Task.sleep(nanoseconds: 150_000_000) } catch {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    let pollResult = await self.runScript(pollJS)
                    guard !Task.isCancelled else {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    switch consumePoll(pollResult, progress: &progress, continuation: continuation) {
                    case .pending:
                        continue
                    case .complete:
                        continuation.finish()
                        return
                    case .failed(let error):
                        continuation.finish(throwing: error)
                        return
                    case .interrupted(let reason):
                        streamingError = reason
                        break pollLoop
                    }
                }

                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                // A dropped connection leaves the provider's operation unknown.
                // Reissuing the prompt could duplicate an in-flight request;
                // incomplete tool fences must never become an executable turn.
                continuation.finish(throwing: AIProviderError.unavailable(
                    reason: "Claude response interrupted: \(streamingError ?? "incomplete stream")."
                        + " No automatic retry.",
                    recoverable: false))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func consumePoll(
        _ result: Result<Data, AIProviderError>, progress: inout PollProgress,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) -> PollOutcome {
        switch result {
        case .failure(let error):
            return .failed(error)
        case .success(let data):
            return consumePollData(data, progress: &progress, continuation: continuation)
        }
    }

    private func consumePollData(
        _ data: Data, progress: inout PollProgress,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) -> PollOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .pending
        }
        if let error = object["err"] as? String, !error.isEmpty {
            return .interrupted(error)
        }
        let buffer = (object["buf"] as? String) ?? ""
        if buffer.count > progress.emittedLength {
            let delta = String(buffer.dropFirst(progress.emittedLength))
            progress.emittedLength = buffer.count
            continuation.yield(delta)
        } else if buffer.isEmpty {
            progress.pollsBeforeAnyText += 1
            if progress.pollsBeforeAnyText >= 400 {
                return .interrupted("no text in 60 s")
            }
        }
        if let done = object["done"] as? Bool, done { return .complete }
        return .pending
    }

}
