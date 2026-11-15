import RemoteAudioProtocol
import XCTest
@testable import VibeRemote

final class DictationBridgeAudioTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationBridgeAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var path: String { directory.appendingPathComponent(DictationAudioFile.fileName).path }

    /// Mirrors the helper's writer: header in a staging file, renamed into place, then samples.
    @discardableResult
    private func writeSession(_ samples: [Float], startedAt: Date = Date(), complete: Bool = true) throws -> UUID {
        let header = DictationAudioFile.Header(session: UUID(), startedAt: startedAt, complete: complete)
        var data = header.encoded()
        for sample in samples { withUnsafeBytes(of: sample.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        let staging = path + ".new"
        try data.write(to: URL(fileURLWithPath: staging))
        XCTAssertEqual(rename(staging, path), 0)
        return header.session
    }

    private func tone(_ count: Int) -> [Float] { (0..<count).map { Float(sin(Double($0) * 0.05) * 0.5) } }

    func testHeaderRoundTripsAndRejectsForeignBytes() {
        let header = DictationAudioFile.Header(session: UUID(), startedAt: Date(timeIntervalSince1970: 1_794_651_610.248))
        let data = header.encoded()
        XCTAssertEqual(data.count, DictationAudioFile.headerSize)
        XCTAssertEqual(DictationAudioFile.Header.decode(data), header)
        var completed = data
        completed.replaceSubrange(32..<36, with: DictationAudioFile.completeFlag())
        XCTAssertEqual(DictationAudioFile.Header.decode(completed)?.complete, true)
        XCTAssertNil(DictationAudioFile.Header.decode(Data(count: 64)))
        XCTAssertNil(DictationAudioFile.Header.decode(data.prefix(40)))
    }

    func testSamplesIgnoreATrailingPartialSample() {
        var data = Data()
        for value: Float in [0.25, -0.5] { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: [0x01, 0x02])
        XCTAssertEqual(DictationAudioFile.samples(in: data), [0.25, -0.5])
    }

    /// The helper stamps the session a few ms before the app dispatches Siri-down; an older
    /// session or one a previous hold took is never this hold's.
    func testSessionAcceptanceRule() {
        let hold = Date(timeIntervalSince1970: 10.257)
        let own = DictationAudioFile.Header(session: UUID(), startedAt: Date(timeIntervalSince1970: 10.248))
        XCTAssertTrue(DictationBridgeAudioReader.accepts(own, holdStartedAt: hold, excluding: [], taken: []))
        XCTAssertFalse(DictationBridgeAudioReader.accepts(own, holdStartedAt: hold, excluding: [own.session], taken: []))
        XCTAssertFalse(DictationBridgeAudioReader.accepts(own, holdStartedAt: hold, excluding: [], taken: [own.session]))
        let stale = DictationAudioFile.Header(session: UUID(), startedAt: Date(timeIntervalSince1970: 7.9))
        XCTAssertFalse(DictationBridgeAudioReader.accepts(stale, holdStartedAt: hold, excluding: [], taken: []))
    }

    func testReaderResamplesOneSessionTo16k() throws {
        let session = try writeSession(tone(48_000))
        let reader = DictationBridgeAudioReader(path: path, holdStartedAt: Date(), excluding: [], followsLaterSessions: false)
        reader.start()
        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertEqual(reader.freeze(), [session])
        let audio = reader.stop()
        XCTAssertEqual(Double(audio.samples.count), 16_000, accuracy: 64)
        XCTAssertGreaterThan(audio.rms, 0.2)
    }

    func testReaderPicksUpSamplesAppendedWhileItPolls() throws {
        let reader = DictationBridgeAudioReader(path: path, holdStartedAt: Date(), excluding: [], followsLaterSessions: false)
        reader.start()
        try writeSession(tone(4_800), complete: false)
        let appended = expectation(description: "appended samples read")
        let path = self.path, samples = tone(4_800)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            let handle = FileHandle(forWritingAtPath: path)!
            handle.seekToEndOfFile()
            var data = Data()
            for sample in samples { withUnsafeBytes(of: sample.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
            handle.write(data)
            handle.closeFile()
            appended.fulfill()
        }
        wait(for: [appended], timeout: 2)
        let audio = reader.stop()
        XCTAssertEqual(Double(audio.samples.count), 3_200, accuracy: 64)
    }

    func testOnlyAFirstGenerationHoldFollowsIntoTheNextSession() throws {
        let first = try writeSession(tone(9_600))
        let single = DictationBridgeAudioReader(path: path, holdStartedAt: Date(), excluding: [], followsLaterSessions: false)
        let follows = DictationBridgeAudioReader(path: path, holdStartedAt: Date(), excluding: [], followsLaterSessions: true)
        single.start()
        follows.start()
        Thread.sleep(forTimeInterval: 0.08)
        // An aluminum hold (one session) ends; the first-generation one is still recording.
        XCTAssertEqual(single.freeze(), [first])
        let second = try writeSession(tone(9_600))
        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertEqual(follows.freeze(), [first, second])
        XCTAssertEqual(Double(follows.stop().samples.count), 6_400, accuracy: 64)
        XCTAssertEqual(Double(single.stop().samples.count), 3_200, accuracy: 64, "frozen before the second session")

        // The next hold never re-reads a session an earlier hold took.
        let next = DictationBridgeAudioReader(path: path, holdStartedAt: Date(), excluding: [first, second],
                                              followsLaterSessions: false)
        next.start()
        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertEqual(next.freeze(), [])
        XCTAssertTrue(next.stop().samples.isEmpty)
    }
}
