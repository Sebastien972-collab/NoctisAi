//
//  NoctisApplicationTests.swift
//  NoctisTests
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//

import Darwin
import Foundation
import Testing
@testable import Noctis
@testable import NoctisCLI

@Suite("Conversation console", .timeLimit(.minutes(1)))
struct NoctisApplicationTests {
    @Test("Charge le moteur avant de transmettre le prompt et affiche les fragments dans l’ordre")
    func loadsBeforeGeneratingAndStreamsResponse() async throws {
        let result = try await #require(
            processExitsWith: .success,
            observing: [\.standardOutputContent]
        ) {
            let service = MockAIModelService(responses: [.chunks(["Bon", "jour", " 🌙"])])

            try await runApplication(input: "Bonjour\nexit\n", modelService: service)

            #expect(service.calls == [.load, .generate("Bonjour")])
        }

        let output = String(decoding: result.standardOutputContent, as: UTF8.self)
        #expect(output.contains("Tout est prêt !"))
        #expect(output.contains("Noctis 🌙 > Bonjour 🌙"))
        #expect(output.contains("🌑 Noctis terminé"))
    }

    @Test("Réutilise le moteur pour plusieurs échanges successifs")
    func handlesSuccessivePromptsWithoutReloading() async throws {
        let result = try await #require(
            processExitsWith: .success,
            observing: [\.standardOutputContent]
        ) {
            let service = MockAIModelService(responses: [
                .chunks(["Première", " réponse"]),
                .chunks(["Seconde", " réponse"])
            ])

            try await runApplication(input: "Premier\nSecond\nexit\n", modelService: service)

            #expect(service.calls == [.load, .generate("Premier"), .generate("Second")])
        }

        let output = String(decoding: result.standardOutputContent, as: UTF8.self)
        let first = try #require(output.range(of: "Noctis 🌙 > Première réponse"))
        let second = try #require(output.range(of: "Noctis 🌙 > Seconde réponse"))
        #expect(first.lowerBound < second.lowerBound)
    }

    @Test("Ignore les lignes vides et retire les espaces autour des prompts")
    func ignoresBlankMessagesAndTrimsPrompts() async throws {
        try await #require(processExitsWith: .success) {
            let service = MockAIModelService(responses: [.chunks(["Réponse"])])

            try await runApplication(input: "\n \t \n  Bonjour  \nexit\n", modelService: service)

            #expect(service.calls == [.load, .generate("Bonjour")])
        }
    }

    @Test("Reconnaît exit sans tenir compte de la casse ni des espaces")
    func exitsWithoutGenerating() async throws {
        try await #require(processExitsWith: .success) {
            let service = MockAIModelService()

            try await runApplication(input: "  ExIt  \nIgnoré\n", modelService: service)

            #expect(service.calls == [.load])
        }
    }

    @Test("Termine normalement à la fin de l’entrée standard")
    func stopsAtEndOfInput() async throws {
        let result = try await #require(
            processExitsWith: .success,
            observing: [\.standardOutputContent]
        ) {
            let service = MockAIModelService()

            try await runApplication(input: "", modelService: service)

            #expect(service.calls == [.load])
        }

        let output = String(decoding: result.standardOutputContent, as: UTF8.self)
        #expect(output.contains("🌑 Noctis terminé"))
    }

    @Test("Un échec de chargement empêche toute génération et affiche l’erreur")
    func loadFailureStopsConversation() async throws {
        let result = try await #require(
            processExitsWith: .success,
            observing: [\.standardOutputContent]
        ) {
            let service = MockAIModelService(loadError: .loadFailed)

            try await runApplication(input: "Bonjour\nexit\n", modelService: service)

            #expect(service.calls == [.load])
        }

        let output = String(decoding: result.standardOutputContent, as: UTF8.self)
        #expect(output.contains("Impossible de démarrer Noctis."))
        #expect(output.contains(MockAIModelService.Failure.loadFailed.rawValue))
        #expect(!output.contains("Tout est prêt !"))
        #expect(output.contains("🌑 Noctis terminé"))
    }

    @Test("Une erreur avant le streaming est affichée et permet l’échange suivant")
    func generationFailureDoesNotStopConversation() async throws {
        let result = try await #require(
            processExitsWith: .success,
            observing: [\.standardOutputContent]
        ) {
            let service = MockAIModelService(responses: [
                .failure(.generationFailed),
                .chunks(["Réponse suivante"])
            ])

            try await runApplication(input: "Premier\nSecond\nexit\n", modelService: service)

            #expect(service.calls == [.load, .generate("Premier"), .generate("Second")])
        }

        let output = String(decoding: result.standardOutputContent, as: UTF8.self)
        let failure = try #require(output.range(of: MockAIModelService.Failure.generationFailed.rawValue))
        let recovery = try #require(output.range(of: "Noctis 🌙 > Réponse suivante"))
        #expect(failure.lowerBound < recovery.lowerBound)
    }

    @Test("Une erreur du flux conserve les fragments reçus et permet l’échange suivant",
          arguments: [[], ["Réponse", " partielle"]])
    func streamFailureDoesNotDiscardChunksOrStopConversation(chunks: [String]) async throws {
        let result = try await #require(
            processExitsWith: .success,
            observing: [\.standardOutputContent]
        ) { [chunks = chunks as [String]] in
            let service = MockAIModelService(responses: [
                .chunks(chunks, finishingWith: .streamFailed),
                .chunks(["Réponse suivante"])
            ])

            try await runApplication(input: "Premier\nSecond\nexit\n", modelService: service)

            #expect(service.calls == [.load, .generate("Premier"), .generate("Second")])
        }

        let output = String(decoding: result.standardOutputContent, as: UTF8.self)
        let partialResponse = "Noctis 🌙 > " + chunks.joined()
        #expect(output.contains(partialResponse + "\nErreur : " + MockAIModelService.Failure.streamFailed.rawValue))
        let failure = try #require(output.range(of: MockAIModelService.Failure.streamFailed.rawValue))
        let recovery = try #require(output.range(of: "Noctis 🌙 > Réponse suivante"))
        #expect(failure.lowerBound < recovery.lowerBound)
    }

    @Test("Un flux sans texte se termine normalement", arguments: [[], ["", ""]])
    func emptyStreamDoesNotStopConversation(chunks: [String]) async throws {
        let result = try await #require(
            processExitsWith: .success,
            observing: [\.standardOutputContent]
        ) { [chunks = chunks as [String]] in
            let service = MockAIModelService(responses: [
                .chunks(chunks),
                .chunks(["Réponse suivante"])
            ])

            try await runApplication(input: "Premier\nSecond\nexit\n", modelService: service)

            #expect(service.calls == [.load, .generate("Premier"), .generate("Second")])
        }

        let output = String(decoding: result.standardOutputContent, as: UTF8.self)
        #expect(output.contains("Noctis 🌙 > \n\n"))
        #expect(output.contains("Noctis 🌙 > Réponse suivante"))
        #expect(!output.contains("Erreur :"))
    }
}

// L’entrée standard n’est remplacée que dans le processus enfant de Swift Testing.
private func runApplication(input: String, modelService: MockAIModelService) async throws {
    let isExitTest = ExitTest.current != nil
    try #require(isExitTest)
    let pipe = Pipe()
    try #require(dup2(pipe.fileHandleForReading.fileDescriptor, STDIN_FILENO) != -1)
    try pipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
    try pipe.fileHandleForWriting.close()

    await NoctisApplication(modelService: modelService).run()
}
