//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared

/// A `Resource` with a scripted behavior, reporting what happens to its
/// streams.
///
/// A stream whose task is cancelled stays active until
/// `releaseCancelledStreams(after:)` lets it end, as a stream which is slow
/// to notice its cancellation.
public final class StubResource: Resource {
    public enum Behavior: Sendable {
        /// The streams deliver the given data in chunks of 16 KB, one per
        /// millisecond.
        case serving(Data)
        /// The streams fail with the given error.
        case failing(ReadError)
        /// The streams deliver nothing until their task is cancelled.
        case holding
        /// The streams deliver the given data as `.serving` does, up to the
        /// limit set by the valve. They end as soon as their task is
        /// cancelled.
        case throttled(Data, Valve)
    }

    /// Limits the bytes delivered by `.throttled` streams, as a network
    /// slower than the playback.
    public final class Valve: Sendable {
        private let state: Mutex<(limit: Int, error: ReadError?, failures: Int)>

        /// - Parameter limit: Offset up to which the data is delivered. The
        ///   streams wait at this offset until the valve opens.
        public init(limit: Int) {
            state = Mutex((limit, nil, 0))
        }

        /// Delivers the rest of the data.
        public func open() {
            state.withLock { $0 = (.max, nil, 0) }
        }

        /// Fails the streams waiting at the limit, and the ones reading
        /// beyond it, with `error`, `times` times.
        public func fail(with error: ReadError, times: Int = .max) {
            state.withLock { $0.error = error; $0.failures = times }
        }

        /// Number of streams which will still fail.
        public var remainingFailures: Int {
            state.withLock { $0.error == nil ? 0 : $0.failures }
        }

        /// Returns the limit, and the error to fail a stream reading at
        /// `offset` with, if any.
        func check(at offset: Int) -> (limit: Int, error: ReadError?) {
            state.withLock { state in
                guard offset >= state.limit, state.failures > 0, let error = state.error else {
                    return (state.limit, nil)
                }
                state.failures -= 1
                return (state.limit, error)
            }
        }
    }

    public enum StreamEvent: Sendable {
        case started
        /// The stream noticed the cancellation of its task.
        case cancelled
    }

    private static let chunkSize = 16384

    private let behavior: Behavior
    private let hasEstimatedLength: Bool
    private let resourceProperties: ReadResult<ResourceProperties>

    private let activeStreams = Mutex(0)
    private let startedStreams = Mutex(0)
    private let events: AsyncStream<StreamEvent>
    private let eventsContinuation: AsyncStream<StreamEvent>.Continuation

    /// Ends once the cancelled streams are released.
    private let release: Task<Void, Never>
    private let releaseContinuation: AsyncStream<Never>.Continuation

    /// - Parameters:
    ///   - hasEstimatedLength: Whether the length is known without reading
    ///     the resource.
    ///   - properties: Result of `properties()`.
    public init(
        _ behavior: Behavior,
        hasEstimatedLength: Bool = true,
        properties: ReadResult<ResourceProperties> = .success(ResourceProperties())
    ) {
        self.behavior = behavior
        self.hasEstimatedLength = hasEstimatedLength
        resourceProperties = properties
        (events, eventsContinuation) = AsyncStream.makeStream()

        let (releases, releaseContinuation) = AsyncStream<Never>.makeStream()
        self.releaseContinuation = releaseContinuation
        release = Task {
            for await _ in releases {}
        }
    }

    public let sourceURL: AbsoluteURL? = nil

    /// Number of streams which did not end yet.
    public var activeStreamCount: Int {
        activeStreams.withLock { $0 }
    }

    /// Valve of a `.throttled` resource.
    public var valve: Valve? {
        if case let .throttled(_, valve) = behavior {
            valve
        } else {
            nil
        }
    }

    /// Number of streams which started.
    public var startedStreamCount: Int {
        startedStreams.withLock { $0 }
    }

    /// Waits until a stream reports `event`. Returns false when none did
    /// after `TimeInterval.testTimeout`.
    public func wait(for event: StreamEvent) async -> Bool {
        await events.first(within: .testTimeout, where: { $0 == event }) != nil
    }

    /// Lets the cancelled streams end, `delay` seconds from now.
    public func releaseCancelledStreams(after delay: TimeInterval) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            releaseContinuation.finish()
        }
    }

    public func estimatedLength() async -> ReadResult<UInt64?> {
        guard hasEstimatedLength else {
            return .success(nil)
        }
        return switch behavior {
        case let .serving(data), let .throttled(data, _): .success(UInt64(data.count))
        case .failing, .holding: .success(1024)
        }
    }

    public func properties() async -> ReadResult<ResourceProperties> {
        resourceProperties
    }

    public func stream(range: Range<UInt64>?, consume: @escaping @Sendable (Data) -> Void) async -> ReadResult<Void> {
        activeStreams.withLock { $0 += 1 }
        startedStreams.withLock { $0 += 1 }
        defer { activeStreams.withLock { $0 -= 1 } }
        eventsContinuation.yield(.started)

        switch behavior {
        case let .serving(data):
            let start = Int(min(range?.lowerBound ?? 0, UInt64(data.count)))
            let end = Int(min(range?.upperBound ?? .max, UInt64(data.count)))
            for offset in stride(from: start, to: end, by: Self.chunkSize) {
                if offset > start {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                    if Task.isCancelled {
                        return await cancelled()
                    }
                }
                consume(data[offset ..< min(offset + Self.chunkSize, end)])
            }
            return .success(())

        case let .failing(error):
            return .failure(error)

        case let .throttled(data, valve):
            var offset = Int(min(range?.lowerBound ?? 0, UInt64(data.count)))
            let end = Int(min(range?.upperBound ?? .max, UInt64(data.count)))
            while offset < end {
                let (limit, error) = valve.check(at: offset)
                if offset < limit {
                    let chunkEnd = min(offset + Self.chunkSize, end, limit)
                    consume(data[offset ..< chunkEnd])
                    offset = chunkEnd
                } else if let error {
                    return .failure(error)
                }
                try? await Task.sleep(nanoseconds: offset < limit ? 1_000_000 : 10_000_000)
                if Task.isCancelled {
                    eventsContinuation.yield(.cancelled)
                    return .failure(.cancelled)
                }
            }
            return .success(())

        case .holding:
            // The sleep ends when the task is cancelled.
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            return await cancelled()
        }
    }

    /// Ends a cancelled stream once it is released.
    private func cancelled() async -> ReadResult<Void> {
        eventsContinuation.yield(.cancelled)
        await release.value
        return .failure(.cancelled)
    }
}
