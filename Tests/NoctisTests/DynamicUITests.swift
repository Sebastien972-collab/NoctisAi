import Foundation
import NoctisPresentation
import Testing
@testable import NoctisCLI
import SwiftTUICLI

@Suite("Dynamic UI protocol")
struct DynamicUITests {
    private func description(revision: Int = 1) -> InterfaceDescription {
        InterfaceDescription(
            revision: revision,
            id: "comparison-1",
            title: "Comparison",
            root: InterfaceNode(
                id: "root",
                type: .column,
                children: [
                    InterfaceNode(id: "title", type: .heading, properties: ["value": .string("Options")]),
                    InterfaceNode(id: "status", type: .status, properties: ["value": .string("Ready")])
                ]
            )
        )
    }

    @Test func decodesAndValidatesKnownComponents() throws {
        let encoded = try JSONEncoder().encode(description())
        let decoded = try InterfaceValidator().decodeAndValidate(encoded)
        #expect(decoded.id == "comparison-1")
        #expect(decoded.root.children.count == 2)
    }

    @Test func rejectsUnknownComponentsAndExcessivePayloads() throws {
        let unknown = Data(#"{"schemaVersion":1,"revision":1,"id":"ui","root":{"id":"root","type":"shell","properties":{},"children":[],"actions":[]}}"#.utf8)
        #expect(throws: DecodingError.self) { try InterfaceValidator().decodeAndValidate(unknown) }

        var limits = InterfaceLimits()
        limits.maximumEncodedBytes = 8
        #expect(throws: InterfaceValidationError.descriptionTooLarge) {
            try InterfaceValidator(limits: limits).decodeAndValidate(Data(repeating: 0, count: 9))
        }
    }

    @Test func appliesIncrementalMutationWithoutChangingStableNodes() throws {
        let original = description()
        let mutation = InterfaceMutation(
            interfaceID: original.id,
            baseRevision: 1,
            revision: 2,
            operation: .update(target: "status", properties: ["value": .string("Complete")])
        )
        let candidate = try InterfaceReconciler().applying(mutation, to: original)
        let updated = try #require(candidate)
        #expect(updated.revision == 2)
        #expect(updated.root.children[0] == original.root.children[0])
        #expect(updated.root.children[1].properties["value"] == .string("Complete"))
        #expect(original.root.children[1].properties["value"] == .string("Ready"))
    }

    @Test func rejectsStaleOrIncompatibleMutationsAtomically() throws {
        let original = description()
        let stale = InterfaceMutation(interfaceID: original.id, baseRevision: 0, revision: 2,
                                      operation: .remove(target: "status"))
        #expect(throws: InterfaceValidationError.invalidRevision) {
            try InterfaceReconciler().applying(stale, to: original)
        }
        let invalid = InterfaceMutation(interfaceID: original.id, baseRevision: 1, revision: 2,
                                        operation: .append(parent: "status", node: .text("child", "No")))
        #expect(throws: InterfaceValidationError.incompatibleMutation) {
            try InterfaceReconciler().applying(invalid, to: original)
        }
        #expect(original.revision == 1)
        #expect(original.root.children.count == 2)
    }

    @Test @MainActor func rendersAtNarrowTerminalWidth() {
        let view = DynamicComponentHost(node: description().root) { _, _ in }
        let output = RenderOnce.render(view, width: 24, environment: ["NO_COLOR": "1", "TERM": "dumb"],
                                       isStdoutTTY: false)
        #expect(output.contains("Options"))
        #expect(output.contains("Ready"))
        #expect(output.split(separator: "\n").allSatisfy { $0.count <= 24 })
    }

    @Test func reconcilerPerformanceIsBounded() throws {
        var current = description()
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            for revision in 2...1_001 {
                let mutation = InterfaceMutation(interfaceID: current.id, baseRevision: revision - 1,
                                                 revision: revision,
                                                 operation: .update(target: "status", properties: ["value": .string("r\(revision)")]))
                let candidate = try InterfaceReconciler().applying(mutation, to: current)
                current = try #require(candidate)
            }
        }
        #expect(elapsed < .seconds(2))
    }

    @Test func structuredStreamPreservesTextAndFallsBackOnInvalidJSON() throws {
        var valid = GenerativeUIStreamAccumulator()
        let encoded = try JSONEncoder().encode(GenerativeUIOutput.create(description()))
        let response = "Voici la comparaison.\n<noctis-ui>\(String(decoding: encoded, as: UTF8.self))</noctis-ui>"
        var visible = ""
        for chunk in response.map(String.init) { visible += valid.append(chunk) }
        let completion = valid.finish()
        visible += completion.text
        #expect(visible == "Voici la comparaison.\n")
        #expect(completion.output == .create(description()))

        var invalid = GenerativeUIStreamAccumulator()
        _ = invalid.append("Réponse<noctis-ui>pas du json</noctis-ui>")
        let fallback = invalid.finish()
        #expect(fallback.output == nil)
        #expect(fallback.text.contains("pas du json"))
    }
}
