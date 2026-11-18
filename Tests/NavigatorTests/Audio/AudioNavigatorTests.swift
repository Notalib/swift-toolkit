//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import AVFoundation
import Foundation
@testable import ReadiumNavigator
@_spi(ExperimentalSelectors) import ReadiumShared
import Testing
import TestSupport

enum AudioNavigatorTests {
    @Suite("Reaching the end of the publication") @MainActor struct EndOfPublication {
        private let audiobook = Audiobook()

        @Test("seeking up to the end of the last resource ends the playback")
        func seekToEndOfLastResource() async {
            // Given the last resource.
            await audiobook.goToResource(at: lastTrackIndex)

            // When seeking up to its end.
            await audiobook.navigator.seek(to: trackDuration)

            // Then the playback is ended, at the end of the last resource.
            #expect(audiobook.navigator.state == .ended)
            #expect(audiobook.states.last == .ended)
            #expect(audiobook.navigator.playbackInfo.resourceIndex == lastTrackIndex)
            #expect(abs(audiobook.navigator.playbackInfo.time - trackDuration) < 0.1)
        }

        @Test("skipping past the end of the publication ends the playback")
        func skipPastEndOfPublication() async {
            // Given the first resource.
            await audiobook.goToResource(at: 0)

            // When skipping by more than the duration of the publication.
            await audiobook.navigator.seek(by: publicationDuration + 1)

            // Then the playback is ended in the last resource.
            #expect(audiobook.navigator.state == .ended)
            #expect(audiobook.states.last == .ended)
            #expect(audiobook.navigator.playbackInfo.resourceIndex == lastTrackIndex)
        }

        @Test("playing up to the end of the last resource ends the playback", .requiresPlayback)
        func playToEndOfLastResource() async {
            // Given a position shortly before the end of the last resource.
            await audiobook.goShortlyBeforeEnd()

            // When playing.
            audiobook.navigator.play()

            // Then the playback is ended after playing the remaining audio.
            await audiobook.waitForPlayback { $0.state == .ended }
            #expect(audiobook.states.contains(.playing))
            #expect(audiobook.navigator.state == .ended)
            #expect(audiobook.navigator.playbackInfo.resourceIndex == lastTrackIndex)
        }
    }

    @Suite("Reaching the end of another resource") @MainActor struct EndOfOtherResource {
        private let audiobook = Audiobook()

        @Test("seeking up to the end of the resource moves on to the next one")
        func seekToEndOfResource() async {
            // Given the first resource.
            await audiobook.goToResource(at: 0)

            // When seeking up to its end.
            await audiobook.navigator.seek(to: trackDuration)

            // Then the navigator moved on to the second resource, without
            // ending the playback.
            #expect(audiobook.navigator.playbackInfo.resourceIndex == 1)
            #expect(audiobook.navigator.state == .paused)
            #expect(!audiobook.states.contains(.ended))
        }

        @Test("a playback held by the delegate at the end of the resource is paused")
        func heldAtEndOfResource() async {
            // Given the first resource, and a delegate refusing to play the
            // next one.
            audiobook.playsNextResource = false
            await audiobook.goToResource(at: 0)

            // When seeking up to its end.
            await audiobook.navigator.seek(to: trackDuration)

            // Then the playback is paused in the first resource, not ended.
            #expect(audiobook.navigator.playbackInfo.resourceIndex == 0)
            #expect(audiobook.navigator.state == .paused)
            #expect(!audiobook.states.contains(.ended))
        }
    }

    @Suite("Once the playback is ended") @MainActor struct Ended {
        private let audiobook = Audiobook()

        /// Given a playback ended by seeking up to the end of the publication.
        init() async {
            await audiobook.goToResource(at: lastTrackIndex)
            await audiobook.navigator.seek(to: trackDuration)
            #expect(audiobook.navigator.state == .ended)
        }

        @Test("pausing and stopping keep it ended")
        func pauseAndStop() {
            // When pausing, then the playback is still ended.
            audiobook.navigator.pause()
            #expect(audiobook.navigator.state == .ended)

            // When stopping, then the playback is still ended.
            audiobook.navigator.stop()
            #expect(audiobook.navigator.state == .ended)
        }

        @Test("seeking back pauses it")
        func seekBack() async {
            // When skipping backward.
            await audiobook.navigator.seek(by: -1)

            // Then the playback is paused in the last resource.
            #expect(audiobook.navigator.state == .paused)
            #expect(audiobook.states.last == .paused)
            #expect(audiobook.navigator.playbackInfo.resourceIndex == lastTrackIndex)
        }

        @Test("jumping to a resource pauses it")
        func jump() async {
            // When jumping to another resource.
            await audiobook.goToResource(at: 1)

            // Then the playback is paused.
            #expect(audiobook.navigator.state == .paused)
            #expect(audiobook.states.last == .paused)
        }

        @Test("playing restarts from the beginning of the publication", .requiresPlayback)
        func play() async throws {
            // When playing.
            audiobook.navigator.play()

            // Then the first resource is playing from its start.
            let playback = try #require(
                await audiobook.waitForPlayback { $0.state == .playing && $0.resourceIndex == 0 }
            )
            #expect(playback.time < trackDuration / 2)
            audiobook.navigator.pause()
        }
    }

    @Suite("shouldPlayNextResource") @MainActor struct ShouldPlayNextResource {
        private let audiobook = Audiobook()

        @Test("is called at the end of each resource but the last one")
        func calledUnlessLastResource() async {
            // Given the first resource.
            await audiobook.goToResource(at: 0)

            // When skipping past the end of the publication.
            await audiobook.navigator.seek(by: publicationDuration + 1)

            // Then the delegate was asked for the first two resources only.
            #expect(audiobook.shouldPlayNextResourceCalls == [0, 1])
        }

        @Test("is not called after playing the last resource", .requiresPlayback)
        func notCalledAfterPlayingLastResource() async {
            // Given a position shortly before the end of the last resource.
            await audiobook.goShortlyBeforeEnd()

            // When playing up to the end of the publication.
            audiobook.navigator.play()
            await audiobook.waitForPlayback { $0.state == .ended }

            // Then the delegate was never asked.
            #expect(audiobook.shouldPlayNextResourceCalls.isEmpty)
        }
    }

    @Suite("Waiting for the audio session") @MainActor struct WaitingForAudioSession {
        private let audioSession = SuspendingAudioSessionManager()
        private let audiobook: Audiobook

        /// Given an audiobook opened at its second resource, with an audio
        /// session which is not ready yet.
        init() {
            audiobook = Audiobook(audioSession: audioSession, initialResourceIndex: 1)
        }

        @Test("playing is reported as loading at the initial location", .requiresPlayback)
        func play() async throws {
            // When playing.
            audiobook.navigator.play()

            // Then the playback is loading at the initial location.
            #expect(audiobook.navigator.state == .loading)
            let loading = try #require(await audiobook.waitForPlayback { $0.state == .loading })
            #expect(loading.resourceIndex == 1)
            #expect(loading.time == 0)

            // When the audio session is ready.
            audioSession.resume()

            // Then the initial resource is playing.
            let playing = try #require(await audiobook.waitForPlayback { $0.state == .playing })
            #expect(playing.resourceIndex == 1)
            audiobook.navigator.pause()
        }

        @Test("pausing cancels the pending play")
        func pause() async throws {
            // When playing, then pausing.
            audiobook.navigator.play()
            audiobook.navigator.pause()

            // Then the playback is paused.
            #expect(audiobook.navigator.state == .paused)
            #expect(audiobook.states.last == .paused)

            // When the audio session is ready.
            audioSession.resume()
            try await Task.sleep(nanoseconds: 200_000_000)

            // Then the playback is still paused.
            #expect(audiobook.navigator.state == .paused)
            #expect(!audiobook.states.contains(.playing))
        }

        @Test("toggling the playback cancels the pending play")
        func playPause() async throws {
            // When playing, then toggling the playback.
            audiobook.navigator.play()
            audiobook.navigator.playPause()

            // Then the playback is paused.
            #expect(audiobook.navigator.state == .paused)
            #expect(audiobook.states.last == .paused)

            // When the audio session is ready.
            audioSession.resume()
            try await Task.sleep(nanoseconds: 200_000_000)

            // Then the playback was not requested again.
            #expect(audiobook.navigator.state == .paused)
            #expect(!audiobook.states.contains(.playing))
        }
    }

    @Suite("Jumping to a temporal locator") @MainActor struct TemporalLocator {
        private let audiobook = Audiobook()

        @Test("seeks to the start of its temporal fragment", arguments: [
            ("t=1", 1),
            ("t=1.25", 1.25),
            ("t=npt:0:00:01", 1),
            ("t=00:01.5&track=audio", 1.5),
            ("t=0.5,1.5", 0.5),
            ("t=,1.5", 0),
        ] as [(URLFragment, Double)])
        func seeksToStart(fragment: URLFragment, expected: Double) async {
            // When jumping to a locator with a temporal fragment.
            await audiobook.go(toResourceAt: 1, fragments: [fragment], progression: 0.9)

            // Then the playback is at the start of the fragment, which wins
            // over the progression.
            #expect(audiobook.navigator.playbackInfo.resourceIndex == 1)
            #expect(abs(audiobook.navigator.playbackInfo.time - expected) < 0.1)
        }

        @Test("falls back on the progression without a valid temporal fragment", arguments: [
            "t=1:30",
            "t=10,",
            "start=1",
        ] as [URLFragment])
        func fallsBackOnProgression(fragment: URLFragment) async {
            // When jumping to a locator whose temporal fragment is invalid.
            await audiobook.go(toResourceAt: 1, fragments: [fragment], progression: 0.5)

            // Then the playback is at the progression.
            #expect(audiobook.navigator.playbackInfo.resourceIndex == 1)
            #expect(abs(audiobook.navigator.playbackInfo.time - trackDuration * 0.5) < 0.1)
        }

        @Test("the current location has a temporal position at the playback time")
        func currentLocation() async throws {
            // When jumping to a locator with a temporal fragment.
            await audiobook.go(toResourceAt: 1, fragments: ["t=1.25"])

            // Then the current location is a position at the playback time.
            let locations = try #require(audiobook.navigator.currentLocation?.locations)
            let temporal = try #require(locations.temporal)
            #expect(temporal == .position(TemporalPosition(time: audiobook.navigator.playbackInfo.time)!))
            #expect(abs(temporal.start - 1.25) < 0.1)
            #expect(locations.fragments == [temporal.fragment])
        }
    }

    @Suite("Queueing the next resource") @MainActor struct QueuedResource {
        private let audiobook = Audiobook()

        @Test("the next resource is queued after the current one")
        func queued() async {
            // When jumping to the first resource.
            await audiobook.goToResource(at: 0)

            // Then the second resource is queued after it.
            #expect(audiobook.navigator.queuedResourceIndex == 1)
            #expect(audiobook.navigator.player.items().count == 2)
        }

        @Test("nothing is queued after the last resource")
        func notQueuedAfterLastResource() async {
            // When jumping to the last resource.
            await audiobook.goToResource(at: lastTrackIndex)

            // Then nothing is queued.
            #expect(audiobook.navigator.queuedResourceIndex == nil)
            #expect(audiobook.navigator.player.items().count == 1)
        }

        @Test("moving on to the next resource plays the queued item")
        func movingOnPlaysQueuedItem() async throws {
            // Given the first resource, with the second one queued.
            await audiobook.goToResource(at: 0)
            await audiobook.waitForQueuedItemPreload()
            let queuedItem = try #require(audiobook.navigator.player.items().last)

            // When seeking up to the end of the first resource.
            await audiobook.navigator.seek(to: trackDuration)

            // Then the queued item is played, and the third resource is
            // queued in turn.
            #expect(audiobook.navigator.playbackInfo.resourceIndex == 1)
            #expect(audiobook.navigator.player.currentItem === queuedItem)
            #expect(audiobook.navigator.queuedResourceIndex == 2)
        }

        @Test("playing up to the end of a resource moves on to the queued item", .requiresPlayback)
        func playingMovesOnToQueuedItem() async throws {
            // Given a position shortly before the end of the first resource,
            // with the second one queued.
            await audiobook.goToResource(at: 0)
            await audiobook.waitForQueuedItemPreload()
            let queuedItem = try #require(audiobook.navigator.player.items().last)
            await audiobook.navigator.seek(to: trackDuration - 0.3)

            // When playing.
            audiobook.navigator.play()

            // Then the playback moves on to the queued item at the end of the
            // first resource.
            await audiobook.waitForPlayback { $0.resourceIndex == 1 && $0.state == .playing }
            #expect(audiobook.navigator.player.currentItem === queuedItem)
            #expect(audiobook.shouldPlayNextResourceCalls == [0])
        }

        @Test("jumping to another resource replaces the queued one")
        func jumpReplacesQueue() async throws {
            // Given the first resource, with the second one queued.
            await audiobook.goToResource(at: 0)
            let queuedItem = try #require(audiobook.navigator.player.items().last)

            // When jumping to the last resource.
            await audiobook.goToResource(at: lastTrackIndex)

            // Then the queued item is dropped.
            #expect(audiobook.navigator.playbackInfo.resourceIndex == lastTrackIndex)
            #expect(audiobook.navigator.player.currentItem !== queuedItem)
            #expect(audiobook.navigator.player.items().count == 1)
            #expect(audiobook.navigator.queuedResourceIndex == nil)

            // When jumping back to the first resource.
            await audiobook.goToResource(at: 0)

            // Then the second resource is queued again.
            #expect(audiobook.navigator.queuedResourceIndex == 1)
        }

        @Test(
            "the next resource waits until the current one is buffered far enough, or is close to its end, and is not loading",
            arguments: [
                (isLoading: false, bufferedAhead: 0.0, remaining: 300.0, queued: false),
                (isLoading: false, bufferedAhead: 19.0, remaining: nil, queued: false),
                (isLoading: false, bufferedAhead: 20.0, remaining: 300.0, queued: true),
                (isLoading: false, bufferedAhead: 0.0, remaining: 45.0, queued: true),
                (isLoading: false, bufferedAhead: 5.0, remaining: 5.0, queued: true),
                (isLoading: true, bufferedAhead: 20.0, remaining: 300.0, queued: false),
                (isLoading: true, bufferedAhead: 0.0, remaining: 45.0, queued: false),
            ] as [(isLoading: Bool, bufferedAhead: Double, remaining: Double?, queued: Bool)]
        )
        func queuedOnceBuffered(isLoading: Bool, bufferedAhead: Double, remaining: Double?, queued: Bool) {
            #expect(
                AudioNavigator.shouldQueueNextResource(
                    isLoading: isLoading,
                    bufferedAhead: bufferedAhead,
                    remaining: remaining
                ) == queued
            )
        }

        @Test("the next resource is queued only once the current one is buffered far enough")
        func queuedOnceCurrentIsBuffered() async throws {
            // Given a long first resource, delivered up to 5 seconds of audio.
            let first = Tracks.throttled(duration: 300, upTo: 5)
            let audiobook = Audiobook(tracks: .stubs([first, Tracks.silent, Tracks.silent]))
            let valve = try #require(first.resource.valve)

            // When playing it.
            await audiobook.goToResource(at: 0)
            audiobook.navigator.play()
            try await Task.sleep(nanoseconds: 1_500_000_000)

            // Then the next resource is not queued.
            #expect(audiobook.navigator.queuedResourceIndex == nil)

            // When the rest of the first resource is delivered.
            valve.open()

            // Then the next resource is queued.
            await audiobook.wait { audiobook.navigator.queuedResourceIndex == 1 }
        }

        @Test("a failure of the current resource does not skip to the queued one")
        func currentResourceFailureDoesNotSkip() async throws {
            // Given a first resource close enough to its end to queue the
            // next one, which fails after 3 seconds of audio.
            let first = Tracks.throttled(duration: 40, upTo: 3)
            let audiobook = Audiobook(tracks: .stubs([first, Tracks.silent, Tracks.silent]))
            let valve = try #require(first.resource.valve)
            await audiobook.goToResource(at: 0)
            await audiobook.wait { audiobook.navigator.queuedResourceIndex == 1 }
            let queuedItem = try #require(audiobook.navigator.player.items().last)
            valve.fail(with: .access(.http(.timeout(nil))))

            // When playing it.
            audiobook.navigator.play()

            // Then the failure is reported for the first resource.
            let failure = try #require(await audiobook.waitForLoadingFailure())
            #expect(failure.href.string == "track1.wav")

            // And the playback stays on the first resource.
            try await Task.sleep(nanoseconds: 2_000_000_000)
            #expect(audiobook.navigator.playbackInfo.resourceIndex == 0)
            #expect(audiobook.navigator.player.currentItem !== queuedItem)
            #expect(audiobook.shouldPlayNextResourceCalls.isEmpty)
        }

        @Test("a queued resource recovers from a transient read error, and plays when moving on")
        func queuedResourceTransientReadError() async throws {
            // Given a second resource whose first read fails.
            let valve = StubResource.Valve(limit: 0)
            valve.fail(with: .access(.http(.timeout(nil))), times: 1)
            let second = Tracks.throttled(duration: trackDuration, upTo: 0, valve: valve)
            let audiobook = Audiobook(tracks: .stubs([Tracks.silent, second, Tracks.silent]))

            // When jumping to the first resource, which queues the second one.
            await audiobook.goToResource(at: 0)
            let queuedItem = try #require(audiobook.navigator.player.items().last)

            // And the second resource can be read after the failure, which
            // is handled before moving on.
            await audiobook.wait { valve.remainingFailures == 0 }
            try await Task.sleep(nanoseconds: 300_000_000)
            valve.open()

            // Then the player reads it again for the same queued item.
            await audiobook.wait { second.resource.startedStreamCount > 1 }
            #expect(audiobook.navigator.queuedResourceIndex == 1)
            #expect(audiobook.navigator.player.items().last === queuedItem)
            await audiobook.waitForQueuedItemPreload()

            // And moving on to it plays the queued item.
            await audiobook.navigator.seek(to: trackDuration)
            #expect(audiobook.navigator.playbackInfo.resourceIndex == 1)
            #expect(audiobook.navigator.player.currentItem === queuedItem)
            #expect(audiobook.loadingFailures.isEmpty)
        }

        @Test("a queued resource which keeps failing to preload is not queued again and again, and is loaded when moving on")
        func queuedResourcePreloadFailure() async throws {
            // Given a second resource which cannot be read yet.
            let valve = StubResource.Valve(limit: 0)
            valve.fail(with: .access(.http(.timeout(nil))))
            let second = Tracks.throttled(duration: trackDuration, upTo: 0, valve: valve)
            let audiobook = Audiobook(tracks: .stubs([Tracks.silent, second, Tracks.silent]))

            // When jumping to the first resource.
            await audiobook.goToResource(at: 0)

            // Then the second resource is dropped from the queue after
            // failing to preload, and is not read again and again.
            await audiobook.wait { second.resource.startedStreamCount > 0 && audiobook.navigator.queuedResourceIndex == nil }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let streamCount = second.resource.startedStreamCount
            try await Task.sleep(nanoseconds: 1_500_000_000)
            #expect(second.resource.startedStreamCount == streamCount)
            #expect(audiobook.navigator.queuedResourceIndex == nil)
            #expect(audiobook.loadingFailures.isEmpty)

            // When the second resource can be read, and the playback moves on
            // to it.
            valve.open()
            await audiobook.navigator.seek(to: trackDuration)

            // Then it is loaded.
            #expect(audiobook.navigator.playbackInfo.resourceIndex == 1)
            await audiobook.wait { audiobook.navigator.player.currentItem?.status == .readyToPlay }
            #expect(audiobook.loadingFailures.isEmpty)
        }

        @Test("a loading failure of the queued resource is reported only once it is played")
        func queuedResourceFailure() async throws {
            // Given an audiobook whose second resource cannot be read, and the
            // first resource, with the second one queued.
            let audiobook = Audiobook(tracks: .failingAfterFirst(.access(.http(.security(nil)))))
            await audiobook.goToResource(at: 0)

            // Then preloading the queued resource reports nothing.
            try await Task.sleep(nanoseconds: 500_000_000)
            #expect(audiobook.loadingFailures.isEmpty)

            // When the playback is held at the end of the first resource, then
            // played, which moves on to the second one.
            audiobook.playsNextResource = false
            await audiobook.navigator.seek(to: trackDuration)
            #expect(audiobook.loadingFailures.isEmpty)
            audiobook.navigator.play()

            // Then its failure is reported.
            let failure = try #require(await audiobook.waitForLoadingFailure())
            #expect(failure.error.isHTTPSecurityError)
            #expect(failure.href.string == "track2.wav")
        }
    }

    @Suite("Failing to load a resource") @MainActor struct LoadingFailure {
        @Test(
            "is reported to the delegate with the HREF of the resource",
            arguments: ["track.wav", "https://example.com/track.wav"]
        )
        func reported(href: String) async throws {
            // Given an audiobook whose resource is missing from the container.
            let audiobook = Audiobook(hrefs: [href], tracks: .missing)

            // When playing.
            audiobook.navigator.play()

            // Then the failure is reported with the HREF of the resource.
            let failure = try #require(await audiobook.waitForLoadingFailure())
            #expect(failure.href.string == href)
        }

        @Test("is reported once, with the error which occurred while reading the resource")
        func reportedWithReadError() async throws {
            // Given an audiobook whose resource cannot be read.
            let audiobook = Audiobook(
                hrefs: ["https://example.com/track.wav"],
                tracks: .failing(.access(.http(.security(nil))))
            )

            // When playing.
            audiobook.navigator.play()

            // Then the failure is reported with the read error and the HREF
            // of the resource.
            let failure = try #require(await audiobook.waitForLoadingFailure())
            #expect(failure.error.isHTTPSecurityError)
            #expect(failure.href.string == "https://example.com/track.wav")

            // And the failure of the player item it caused is not reported on
            // top of it.
            try await Task.sleep(nanoseconds: 500_000_000)
            #expect(audiobook.loadingFailures.count == 1)
        }
    }
}

private extension Trait where Self == ConditionTrait {
    /// Skips a test waiting for the player to actually play audio when running
    /// on the CI, as the playback does not start on its runners.
    static var requiresPlayback: Self {
        .disabled(
            if: ProcessInfo.processInfo.environment["CI"] != nil,
            "The playback does not start on the CI runners"
        )
    }
}

private let trackCount = 3
private let trackDuration: Double = 2
private let lastTrackIndex = trackCount - 1
private let publicationDuration = Double(trackCount) * trackDuration

/// How the tracks of an `Audiobook` are served by its container.
private enum Tracks {
    /// The tracks are silent audio files.
    case silence
    /// The tracks are missing from the container.
    case missing
    /// Reading the tracks fails with the given error.
    case failing(ReadError)
    /// The first track is a silent audio file, reading the others fails with
    /// the given error.
    case failingAfterFirst(ReadError)
    /// Each track is a resource of the given duration, in seconds.
    case stubs([(duration: Double, resource: StubResource)])

    /// A silent track of `duration` seconds, delivered up to `seconds` of
    /// audio until `valve` opens.
    static func throttled(duration: Double, upTo seconds: Double, valve: StubResource.Valve? = nil) -> (duration: Double, resource: StubResource) {
        let valve = valve ?? StubResource.Valve(limit: WAV.headerSize + Int(seconds * 16000))
        return (duration, StubResource(.throttled(WAV.silence(duration: duration), valve)))
    }

    /// A silent track of `trackDuration` seconds.
    static var silent: (duration: Double, resource: StubResource) {
        (trackDuration, StubResource(.serving(WAV.silence(duration: trackDuration))))
    }
}

/// A `Container` serving the given resources.
private struct ResourceContainer: Container, @unchecked Sendable {
    let sourceURL: AbsoluteURL? = nil
    let resources: [AnyURL: Resource]

    var entries: Set<AnyURL> {
        Set(resources.keys)
    }

    subscript(url: any URLConvertible) -> Resource? {
        resources[url.anyURL.normalized]
    }
}

/// A `Container` whose entries all fail to be read with `error`.
private struct FailingContainer: Container {
    let sourceURL: AbsoluteURL? = nil
    let entries: Set<AnyURL>
    let error: ReadError

    subscript(url: any URLConvertible) -> Resource? {
        entries.contains(url.anyURL.normalized) ? FailureResource(error: error) : nil
    }
}

private extension ReadError {
    var isHTTPSecurityError: Bool {
        if case .access(.http(.security)) = self {
            true
        } else {
            false
        }
    }
}

/// An audiobook of `trackCount` silent tracks played by a real
/// `AudioNavigator`, recording the events sent to its delegate.
@MainActor private final class Audiobook: AudioNavigatorDelegate {
    let navigator: AudioNavigator

    /// Answer to the navigator asking whether to play the next resource.
    var playsNextResource = true

    /// Playback states reported by the navigator.
    private(set) var states: [MediaPlaybackState] = []

    /// Playbacks reported by the navigator, buffered until they are waited
    /// for.
    private let playbacks: AsyncStream<MediaPlaybackInfo>
    private let playbacksContinuation: AsyncStream<MediaPlaybackInfo>.Continuation

    /// Indices of the resources for which the navigator asked whether to play
    /// the next one.
    private(set) var shouldPlayNextResourceCalls: [Int] = []

    typealias LoadingFailure = (href: AnyURL, error: ReadError)

    /// Resources which failed to load, as reported by the navigator.
    private(set) var loadingFailures: [LoadingFailure] = []

    /// Loading failures reported by the navigator, buffered until they are
    /// waited for.
    private let loadingFailuresStream: AsyncStream<LoadingFailure>
    private let loadingFailuresContinuation: AsyncStream<LoadingFailure>.Continuation

    /// - Parameter initialResourceIndex: Index in the reading order of the
    ///   resource the navigator starts from, instead of the first one.
    /// - Parameter hrefs: HREFs of the tracks in the reading order.
    /// - Parameter tracks: How the tracks are served by the container.
    init(
        audioSession: any AudioSessionManaging = NoopAudioSessionManager(),
        initialResourceIndex: Int? = nil,
        hrefs: [String]? = nil,
        tracks: Tracks = .silence
    ) {
        var durations = [Double](repeating: trackDuration, count: trackCount)
        if case let .stubs(stubs) = tracks {
            durations = stubs.map(\.duration)
        }
        let hrefs = hrefs ?? durations.indices.map { "track\($0 + 1).wav" }
        (playbacks, playbacksContinuation) = AsyncStream.makeStream()
        (loadingFailuresStream, loadingFailuresContinuation) = AsyncStream.makeStream()

        let urls = hrefs.map { AnyURL(string: $0)! }
        let container: any Container = switch tracks {
        case .silence:
            DataContainer(
                entries: Dictionary(uniqueKeysWithValues: urls.map { ($0, WAV.silence(duration: trackDuration)) })
            )
        case .missing:
            DataContainer(entries: [:])
        case let .failing(error):
            FailingContainer(entries: Set(urls), error: error)
        case let .failingAfterFirst(error):
            CompositeContainer(
                DataContainer(entries: [urls[0]: WAV.silence(duration: trackDuration)]),
                FailingContainer(entries: Set(urls.dropFirst()), error: error)
            )
        case let .stubs(stubs):
            ResourceContainer(resources: Dictionary(uniqueKeysWithValues: zip(urls, stubs.map(\.resource))))
        }
        let publication = Publication(
            manifest: Manifest(
                metadata: Metadata(conformsTo: [.audiobook], title: "Audiobook"),
                readingOrder: zip(hrefs, durations).map {
                    Link(href: $0, mediaType: .wav, duration: $1)
                }
            ),
            container: container
        )

        navigator = AudioNavigator(
            publication: publication,
            initialLocation: initialResourceIndex.flatMap {
                publication.locator(for: publication.readingOrder[$0])
            },
            audioSession: audioSession
        )
        navigator.delegate = self
    }

    /// Jumps to the start of the resource at `index` in the reading order.
    func goToResource(at index: Int) async {
        #expect(await navigator.go(to: navigator.readingOrder[index]))
    }

    /// Jumps to a locator in the resource at `index` in the reading order.
    func go(toResourceAt index: Int, fragments: [URLFragment], progression: Double? = nil) async {
        let link = navigator.readingOrder[index]
        let locator = Locator(
            href: link.url(),
            mediaType: .wav,
            locations: .init(fragments: fragments, progression: progression)
        )
        #expect(await navigator.go(to: locator))
    }

    /// Jumps shortly before the end of the last resource, so that playing
    /// reaches the end of the publication quickly.
    func goShortlyBeforeEnd() async {
        await goToResource(at: lastTrackIndex)
        await navigator.seek(to: trackDuration - 0.3)
    }

    /// Waits for the navigator to report a playback matching `condition`, or
    /// fails the test after `timeout` seconds.
    ///
    /// The playbacks reported before waiting are checked too.
    @discardableResult
    func waitForPlayback(
        timeout: TimeInterval = .testTimeout,
        sourceLocation: SourceLocation = #_sourceLocation,
        where condition: @escaping @Sendable (MediaPlaybackInfo) -> Bool
    ) async -> MediaPlaybackInfo? {
        guard let playback = await playbacks.first(within: timeout, where: condition) else {
            Issue.record("Timed out waiting for the playback", sourceLocation: sourceLocation)
            return nil
        }
        return playback
    }

    /// Waits until `condition` is true, or fails the test after `timeout`
    /// seconds.
    func wait(
        timeout: TimeInterval = .testTimeout,
        sourceLocation: SourceLocation = #_sourceLocation,
        until condition: () -> Bool
    ) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("Timed out waiting for the condition", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Waits until the asset of the queued item is preloaded, so that moving
    /// on plays the queued item.
    func waitForQueuedItemPreload(sourceLocation: SourceLocation = #_sourceLocation) async {
        await wait(sourceLocation: sourceLocation) {
            guard
                navigator.queuedResourceIndex != nil,
                let item = navigator.player.items().dropFirst().first,
                case .loaded = item.asset.status(of: .duration)
            else {
                return false
            }
            return true
        }
    }

    /// Waits for the navigator to report a resource which failed to load, or
    /// fails the test after `timeout` seconds.
    ///
    /// The failures reported before waiting are checked too.
    func waitForLoadingFailure(
        timeout: TimeInterval = .testTimeout,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> LoadingFailure? {
        guard let failure = await loadingFailuresStream.first(within: timeout) else {
            Issue.record("Timed out waiting for a loading failure", sourceLocation: sourceLocation)
            return nil
        }
        return failure
    }

    func navigator(_ navigator: AudioNavigator, playbackDidChange info: MediaPlaybackInfo) {
        states.append(info.state)
        playbacksContinuation.yield(info)
    }

    func navigator(_ navigator: AudioNavigator, shouldPlayNextResource info: MediaPlaybackInfo) -> Bool {
        shouldPlayNextResourceCalls.append(info.resourceIndex)
        return playsNextResource
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}

    func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: AnyURL, withError error: ReadError) {
        loadingFailures.append((href, error))
        loadingFailuresContinuation.yield((href, error))
    }
}
