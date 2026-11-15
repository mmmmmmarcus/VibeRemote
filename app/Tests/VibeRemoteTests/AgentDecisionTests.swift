import Foundation
import XCTest
@testable import VibeRemote

final class AgentDecisionTests: XCTestCase {
    private let candidates = [AgentDecisionCandidate(id: "open_notes", label: "Open Notes")]

    func testDedicatedDecisionsRequestAndValidatedSelection() async throws {
        let fixture = Fixture(.response(200, Self.answer()))
        defer { fixture.close() }
        let selected = try await fixture.client.select(command: "Open Notes", candidates: candidates, apiKey: "test-key")
        XCTAssertEqual(selected, "open_notes")
        let request = try XCTUnwrap(DecisionURLProtocol.registry.request(for: fixture.id))
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/alpha/decisions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.timeoutInterval, 3)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "typesafe/jev-1.14")
        XCTAssertNil(body["messages"])
        XCTAssertEqual((body["state"] as? [String: String])?["command"], "Open Notes")
        let question = try XCTUnwrap((body["questions"] as? [String: [String: Any]])?["action"])
        XCTAssertEqual(question["type"] as? String, "choice")
        let criteria = try XCTUnwrap(question["criteria"] as? [String: String])
        XCTAssertEqual(criteria["open_notes"], "Open Notes")
        XCTAssertNotNil(criteria[AgentDecisionClient.escalationID])
        XCTAssertEqual(criteria.count, 2)
    }

    func testAbstentionAndLowConfidenceCannotSelectAnAction() async throws {
        for data in [Self.answer(choice: "__escalate", probability: 0.02, confidence: 0.9),
                     Self.answer(probability: 0.6, confidence: 0.7),
                     Self.answer(probability: 0.98, confidence: 0.1)] {
            let fixture = Fixture(.response(200, data))
            defer { fixture.close() }
            let selected = try await fixture.client.select(command: "Open Notes", candidates: candidates, apiKey: "test-key")
            XCTAssertNil(selected)
        }
    }

    func testMalformedMissingAndInjectedChoicesFailClosed() async {
        let invalid = [
            #"{}"#,
            #"{"answers":{}}"#,
            #"{"answers":{"action":{"type":"choice","choice":"run_shell","confidence":1,"probabilities":{"run_shell":1}}}}"#,
            #"{"answers":{"action":{"type":"choice","choice":"open_notes","confidence":0.9}}}"#,
            #"{"answers":{"action":{"type":"choice","choice":"open_notes","confidence":1.1,"probabilities":{"open_notes":0.9,"__escalate":0.1}}}}"#,
            #"{"answers":{"action":{"type":"choice","choice":"open_notes","confidence":0.9,"probabilities":{"open_notes":1.2,"__escalate":-0.2}}}}"#,
            #"{"answers":{"action":{"type":"choice","choice":"open_notes","confidence":0.9,"probabilities":{"open_notes":0.9,"__escalate":0.1,"injected":0}}}}"#,
            #"{"answers":{"action":{"type":"choice","choice":"open_notes","confidence":0.9,"probabilities":{"open_notes":0.9,"__escalate":0.9}}}}"#,
            #"{"answers":{"action":{"type":"choice","choice":"open_notes","confidence":0.9,"probabilities":{"open_notes":0.1,"__escalate":0.9}}}}"#,
            #"{"answers":{"action":{"type":"choice","choice":"open_notes","confidence":NaN,"probabilities":{"open_notes":0.9,"__escalate":0.1}}}}"#,
            #"{"answers":{"action":{"type":"choice","choice":"open_notes","confidence":0.9,"probabilities":{"open_notes":1e999,"__escalate":0}}}}"#
        ]
        for text in invalid {
            let fixture = Fixture(.response(200, Data(text.utf8)))
            defer { fixture.close() }
            await assertFailure(.invalidResponse, fixture: fixture)
        }
    }

    func testHTTPAndTransportFailuresDoNotExposeProviderText() async {
        let http = Fixture(.response(401, Data(#"{"error":{"message":"private-command test-key"}}"#.utf8)))
        defer { http.close() }
        await assertFailure(.httpStatus(401), fixture: http)
        let transport = Fixture(.failure(URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "test-key"])))
        defer { transport.close() }
        await assertFailure(.unavailable, fixture: transport)
        let timeout = Fixture(.failure(URLError(.timedOut)))
        defer { timeout.close() }
        await assertFailure(.timedOut, fixture: timeout)
    }

    func testReservedOrDuplicateIDsAreRejectedBeforeNetworking() async {
        for offered in [
            [AgentDecisionCandidate(id: "__escalate", label: "Override abstention")],
            candidates + candidates,
            [],
            [AgentDecisionCandidate(id: "", label: "Open Notes")]
        ] {
            let fixture = Fixture(.response(200, Self.answer()))
            defer { fixture.close() }
            do {
                _ = try await fixture.client.select(command: "Open Notes", candidates: offered, apiKey: "test-key")
                XCTFail("Invalid candidates were accepted")
            } catch { XCTAssertEqual(error as? AgentDecisionClient.Failure, .invalidRequest) }
            XCTAssertNil(DecisionURLProtocol.registry.request(for: fixture.id))
        }
    }

    func testCancellationCancelsTheUnderlyingURLSessionRequest() async throws {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "request cancelled")
        let fixture = Fixture(.pending(started, stopped))
        defer { fixture.close() }
        let client = fixture.client
        let offered = candidates
        let task = Task { try await client.select(command: "Open Notes", candidates: offered, apiKey: "test-key") }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled decision was accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testDeadlineCancelsAResponseThatNeverFinishes() async {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "deadline cancelled request")
        let fixture = Fixture(.pending(started, stopped))
        defer { fixture.close() }
        let start = ContinuousClock.now
        await assertFailure(.timedOut, fixture: fixture)
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(5))
        await fulfillment(of: [started, stopped], timeout: 1)
    }

    private func assertFailure(_ expected: AgentDecisionClient.Failure, fixture: Fixture,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await fixture.client.select(command: "Open Notes", candidates: candidates, apiKey: "test-key")
            XCTFail("Expected failure", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AgentDecisionClient.Failure, expected, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("test-key"), file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("private-command"), file: file, line: line)
        }
    }

    private static func answer(choice: String = "open_notes", probability: Double = 0.98,
                               confidence: Double = 0.9) -> Data {
        try! JSONSerialization.data(withJSONObject: ["answers": ["action": [
            "type": "choice", "choice": choice, "confidence": confidence,
            "probabilities": ["open_notes": probability, "__escalate": 1 - probability]
        ]]])
    }

    private static func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private struct Fixture {
        let id = UUID().uuidString
        let session: URLSession
        var client: AgentDecisionClient { AgentDecisionClient(session: session) }

        init(_ behavior: DecisionURLProtocol.Behavior) {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [DecisionURLProtocol.self]
            config.httpAdditionalHeaders = ["X-Decision-Test-ID": id]
            session = URLSession(configuration: config)
            DecisionURLProtocol.registry.install(behavior, for: id)
        }

        func close() {
            session.invalidateAndCancel()
            DecisionURLProtocol.registry.remove(id)
        }
    }
}

/// Each test session has its own ID, so mock replies cannot cross even under parallel tests.
private final class DecisionURLProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior: Sendable {
        case response(Int, Data)
        case failure(URLError)
        case pending(XCTestExpectation, XCTestExpectation)
    }

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var behaviors: [String: Behavior] = [:]
        private var requests: [String: URLRequest] = [:]
        func install(_ value: Behavior, for id: String) {
            lock.lock(); defer { lock.unlock() }; behaviors[id] = value
        }
        func begin(_ request: URLRequest, id: String) -> Behavior? {
            lock.lock(); defer { lock.unlock() }; requests[id] = request; return behaviors[id]
        }
        func request(for id: String) -> URLRequest? {
            lock.lock(); defer { lock.unlock() }; return requests[id]
        }
        func remove(_ id: String) {
            lock.lock(); defer { lock.unlock() }; behaviors[id] = nil; requests[id] = nil
        }
    }

    static let registry = Registry()
    private var stopped: XCTestExpectation?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Decision-Test-ID"),
              let behavior = Self.registry.begin(request, id: id) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        switch behavior {
        case .response(let code, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
        case .pending(let started, let stopped): self.stopped = stopped; started.fulfill()
        }
    }
    override func stopLoading() { stopped?.fulfill(); stopped = nil }
}
