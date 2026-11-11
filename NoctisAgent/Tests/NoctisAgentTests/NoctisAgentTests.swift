// Created by Sébastien DAGUIN

import Foundation
import Darwin
import Testing
@testable import NoctisAgent

private struct Fixture {
    let directory: URL
    let workspace: AuthorizedWorkspace
    var registry: ToolRegistry { ToolRegistry(workspace: workspace) }

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workspace = try AuthorizedWorkspace(authorizing: directory)
    }

    func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: directory.appendingPathComponent(name))
    }

    func clean() { try? FileManager.default.removeItem(at: directory) }

    func call(_ name: String, _ arguments: [String: String]) throws -> String {
        try registry.execute(.init(id: UUID().uuidString, name: name, arguments: arguments))
    }
}

private actor ScriptedModel: AgentModel {
    var responses: [AgentResponse]
    var observations: [[AgentMessage]] = []

    init(_ responses: [AgentResponse]) { self.responses = responses }

    func respond(messages: [AgentMessage], tools: [AgentToolSchema],
                 limits: AgentLimits) async throws -> AgentResponse {
        observations.append(messages)
        return responses.isEmpty ? AgentResponse(text: "done") : responses.removeFirst()
    }
}

@Suite("Read-only workspace")
struct WorkspaceTests {
    @Test func listingReadingAndLiteralSearch() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.write("Example.swift", "first\nlet answer = 42\nlast")
        let listing = try fixture.call("listFiles", ["path": "."])
        #expect(listing.contains("Example.swift"))
        #expect(try fixture.call("listFiles", ["path": "."]) == listing)
        #expect(try fixture.call("readFile", ["path": "Example.swift"]).contains("answer = 42"))
        let result = try fixture.call("searchCode", ["path": ".", "query": "answer ="])
        #expect(result.contains("\"line\":2"))
        #expect(result.contains("UNTRUSTED_WORKSPACE_DATA"))
        #expect(try fixture.call("searchCode", ["path": ".", "query": "a.*"]).contains("\"matches\":[]"))
    }

    @Test(arguments: ["../secret", "sub/../../secret", "/etc/passwd", "bad\0file", ""])
    func rejectsInvalidPaths(path: String) throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        #expect(try fixture.call("readFile", ["path": path]).contains("error"))
    }

    @Test func rejectsSymlinksIncludingInternalAndRoot() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.write("real", "secret")
        for (name, target) in [("outside", "/etc"), ("inside", fixture.directory.path)] {
            try FileManager.default.createSymbolicLink(atPath: fixture.directory.appendingPathComponent(name).path,
                                                      withDestinationPath: target)
            #expect(try fixture.call("readFile", ["path": name + "/real"]).contains("accessDenied"))
            #expect(throws: AgentError.self) {
                try AuthorizedWorkspace(authorizing: fixture.directory.appendingPathComponent(name))
            }
        }
    }

    @Test func rejectsSpecialFilesHardlinksBinaryAndOversize() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.write("large", String(repeating: "a", count: 65_537))
        try fixture.write("real", "secret")
        try FileManager.default.linkItem(at: fixture.directory.appendingPathComponent("real"),
                                        to: fixture.directory.appendingPathComponent("hard"))
        try Data([0xff, 0xfe]).write(to: fixture.directory.appendingPathComponent("binary"))
        #expect(mkfifo(fixture.directory.appendingPathComponent("fifo").path, 0o600) == 0)
        #expect(try fixture.call("readFile", ["path": "fifo"]).contains("notRegularFile"))
        #expect(try fixture.call("readFile", ["path": "hard"]).contains("notRegularFile"))
        #expect(try fixture.call("readFile", ["path": "binary"]).contains("invalidUTF8"))
        #expect(try fixture.call("readFile", ["path": "large"]).contains("fileTooLarge"))
        #expect(try fixture.call("readFile", ["path": "."]).contains("notRegularFile"))
    }

    @Test func rootDescriptorRemainsPinned() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.write("real", "original")
        let moved = fixture.directory.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: fixture.directory, to: moved)
        try FileManager.default.createSymbolicLink(atPath: fixture.directory.path, withDestinationPath: "/etc")
        #expect(try fixture.call("readFile", ["path": "real"]).contains("original"))
        #expect(try fixture.call("readFile", ["path": "passwd"]).contains("error"))
    }

    @Test func ancestorReplacementCannotEscapeWorkspace() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let safe = fixture.directory.appendingPathComponent("safe")
        let held = fixture.directory.appendingPathComponent("held")
        let outside = fixture.directory.appendingPathExtension("outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: safe.appendingPathComponent("document.txt"))
        try Data("OUTSIDE_SECRET".utf8).write(to: outside.appendingPathComponent("document.txt"))
        #expect(try fixture.call("readFile", ["path": "safe/document.txt"]).contains("inside"))
        let swap = Task.detached {
            for _ in 0..<200 {
                if rename(safe.path, held.path) != 0 { continue }
                symlink(outside.path, safe.path)
                unlink(safe.path)
                rename(held.path, safe.path)
            }
        }
        for _ in 0..<300 {
            let result = try fixture.call("readFile", ["path": "safe/secret"])
            #expect(!result.contains("OUTSIDE_SECRET"))
        }
        await swap.value
    }

    @Test func escapedOutputCannotExceedResultBudget() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.write("escaped", String(repeating: "\u{01}", count: 65_536))
        #expect(try fixture.call("readFile", ["path": "escaped"]).contains("responseLimit"))
    }

    @Test func schemasArgumentsAndDisabledTools() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        #expect(fixture.registry.schemas.map(\.name) == ["listFiles", "readFile", "searchCode"])
        for name in ["applyPatch", "runCommand", "gitDiff", "unknown"] {
            #expect(try fixture.call(name, ["path": "."]).contains("unsupportedTool"))
        }
        #expect(try fixture.call("listFiles", ["path": ".", "extra": "no"]).contains("invalidArguments"))
        #expect(try fixture.call("readFile", [:]).contains("invalidArguments"))
        #expect(try fixture.call("searchCode", ["path": ".", "query": ""]).contains("invalidArguments"))
    }

    @Test func searchAndListingAreBounded() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.write("many.swift", String(repeating: "match\n", count: 100))
        let search = try fixture.call("searchCode", ["path": ".", "query": "match"])
        #expect(search.contains("\"truncated\":true"))
        let json = try #require(JSONSerialization.jsonObject(with: Data(search.utf8)) as? [String: Any])
        #expect((json["matches"] as? [Any])?.count == 50)
        for index in 0..<210 { try fixture.write("file\(index)", "") }
        #expect(try fixture.call("listFiles", ["path": "."]).contains("\"truncated\":true"))
    }
}

@Suite("Agent loop")
struct RuntimeTests {
    @Test func callsThenAnswerAndFreshSession() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.write("test.swift", "let value = 1")
        let model = ScriptedModel([
            .init(calls: [.init(id: "read", name: "readFile", arguments: ["path": "test.swift"])]),
            .init(text: "Found value")
        ])
        let runtime = AgentRuntime(model: model, registry: fixture.registry, limits: try AgentLimits())
        let result = try await runtime.run(prompt: "Inspect")
        #expect(result.status == .completed)
        #expect(result.iterations == 2)
        #expect(result.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        let seen = await model.observations
        #expect(seen[1][2].callID == "read")
        #expect(seen[1][2].content.contains("value = 1"))
        let next = try await runtime.run(prompt: "Again")
        #expect(next.id != result.id)
        #expect(next.messages.count == 2)
    }

    @Test func toolErrorsReturnToModel() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let model = ScriptedModel([
            .init(calls: [.init(id: "bad", name: "runCommand", arguments: [:])]), .init(text: "Cannot run")
        ])
        let runtime = AgentRuntime(model: model, registry: fixture.registry, limits: try AgentLimits())
        let result = try await runtime.run(prompt: "Test")
        #expect(result.messages[2].content.contains("unsupportedTool"))
        #expect(result.status == .completed)
    }

    @Test func iterationLimitAndDuplicateIDs() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let call = AgentToolCall(id: "same", name: "listFiles", arguments: ["path": "."])
        let runtime = AgentRuntime(model: ScriptedModel([.init(calls: [call])]),
                                   registry: fixture.registry, limits: try AgentLimits(iterations: 1))
        #expect(try await runtime.run(prompt: "Loop").status == .iterationLimit)
        let duplicate = AgentRuntime(model: ScriptedModel([.init(calls: [call, call])]),
                                     registry: fixture.registry, limits: try AgentLimits())
        await #expect(throws: AgentError.invalidToolCall) { try await duplicate.run(prompt: "Bad") }
        #expect(await duplicate.session.messages.count == 1)
    }

    @Test func contextAndResponseLimits() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let runtime = AgentRuntime(model: ScriptedModel([]), registry: fixture.registry,
                                   limits: try AgentLimits(contextBytes: 1_024))
        await #expect(throws: AgentError.contextLimit) {
            try await runtime.run(prompt: String(repeating: "x", count: 2_000))
        }
        let oversized = AgentRuntime(model: ScriptedModel([.init(text: String(repeating: "x", count: 257))]),
                                     registry: fixture.registry, limits: try AgentLimits(responseBytes: 256))
        await #expect(throws: AgentError.responseLimit) { try await oversized.run(prompt: "Hello") }
        #expect(throws: AgentError.invalidLimits) { try AgentLimits(iterations: 0) }
    }

    @Test func cancellationAndBusyGuard() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let model = WaitingModel()
        let runtime = AgentRuntime(model: model, registry: fixture.registry, limits: try AgentLimits())
        let task = Task { try await runtime.run(prompt: "Wait") }
        await model.waitUntilStarted()
        await #expect(throws: AgentError.busy) { try await runtime.run(prompt: "Overlap") }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await runtime.session.status == .cancelled)
    }
}

private actor WaitingModel: AgentModel {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func respond(messages: [AgentMessage], tools: [AgentToolSchema],
                 limits: AgentLimits) async throws -> AgentResponse {
        started = true
        waiters.forEach { $0.resume() }
        waiters = []
        try await Task.sleep(for: .seconds(30))
        return .init(text: "done")
    }
}
