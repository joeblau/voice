import Testing

@testable import BlauTranscription

@Suite("RecentAudio")
struct RecentAudioTests {
    @Test func keepsTheNewestSamplesByAbsoluteOffset() throws {
        var ring = RecentAudio(capacity: 10)
        ring.reset(at: 100)
        ring.append((0..<7).map { Float($0) }[...])
        #expect(ring.range == 100..<107)
        ring.append((7..<15).map { Float($0) }[...])
        #expect(ring.range == 105..<115)
        let read = try #require(ring.samples(in: 103..<112))
        #expect(read.offset == 105)
        #expect(read.samples == (5..<12).map { Float($0) })
        #expect(ring.samples(in: 0..<105) == nil)
        #expect(ring.samples(in: 115..<120) == nil)
    }

    @Test func aLongAppendKeepsOnlyItsTail() throws {
        var ring = RecentAudio(capacity: 4)
        ring.append((0..<10).map { Float($0) }[...])
        #expect(ring.range == 6..<10)
        #expect(try #require(ring.samples(in: 0..<10)).samples == [6, 7, 8, 9])
    }
}
