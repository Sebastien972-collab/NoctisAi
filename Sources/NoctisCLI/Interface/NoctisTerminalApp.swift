import Foundation
import Noctis
import NoctisAgent
import NoctisPresentation
import Observation
import SwiftTUI
import SwiftTUICLI

@MainActor @Observable
final class ConversationUIState {
    struct Message: Identifiable, Sendable {
        enum Role: Sendable, Equatable { case user, assistant, status, error }
        let id: UUID
        let role: Role
        var text: String
    }

    var messages: [Message] = []
    var prompt = ""
    var isGenerating = false
    var interface: InterfaceDescription?
    var interfaceError: String?

    private let modelService: any AIModelService
    private var loaded = false
    private var generation: Task<Void, Never>?

    init(modelService: any AIModelService) {
        self.modelService = modelService
    }

    func submit() {
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isGenerating else { return }
        prompt = ""
        if value == "/clear" {
            generation?.cancel()
            messages.removeAll(keepingCapacity: true)
            interface = nil
            Task { try? await modelService.resetConversation(history: []) }
            return
        }
        if value == "/exit" || value == "exit" { return }
        messages.append(Message(id: UUID(), role: .user, text: value))
        let responseID = UUID()
        messages.append(Message(id: responseID, role: .assistant, text: ""))
        isGenerating = true
        generation = Task { [weak self] in
            guard let self else { return }
            do {
                if !loaded { try await modelService.load(); loaded = true }
                try Task.checkCancellation()
                let accumulator = GenerativeUIStreamAccumulatorBox()
                let structuredPrompt = value + "\n\n" + GenerativeUIProtocol.modelInstruction
                try await modelService.withResponse(prompt: structuredPrompt) { stream in
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        let visible = await accumulator.append(chunk)
                        if !visible.isEmpty { await MainActor.run { self.append(visible, to: responseID) } }
                    }
                }
                let completion = accumulator.finish()
                if !completion.text.isEmpty { append(completion.text, to: responseID) }
                if let output = completion.output { apply(output) }
            } catch is CancellationError {
                await modelService.cancelGeneration()
                append("\n\n_Réponse interrompue._", to: responseID)
            } catch {
                append("\n\nErreur : \(TerminalMarkdown.sanitized(error.localizedDescription))", to: responseID)
            }
            isGenerating = false
        }
    }

    func cancel() {
        generation?.cancel()
    }

    func apply(_ description: InterfaceDescription) {
        do {
            try InterfaceValidator().validate(description)
            interface = description
            interfaceError = nil
        } catch {
            interfaceError = "Interface ignorée : \(error)"
        }
    }

    func apply(_ mutation: InterfaceMutation) {
        guard let current = interface else { interfaceError = "Interface cible absente"; return }
        do {
            interface = try InterfaceReconciler().applying(mutation, to: current)
            interfaceError = nil
        } catch {
            interfaceError = "Mise à jour ignorée : \(error)"
        }
    }

    private func apply(_ output: GenerativeUIOutput) {
        switch output {
        case .create(let description): apply(description)
        case .mutate(let mutation), .dismiss(let mutation): apply(mutation)
        }
    }

    private func append(_ chunk: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += chunk
    }
}

@MainActor
private final class GenerativeUIStreamAccumulatorBox {
    private var accumulator = GenerativeUIStreamAccumulator()

    func append(_ chunk: String) -> String { accumulator.append(chunk) }
    func finish() -> (text: String, output: GenerativeUIOutput?) { accumulator.finish() }
}

struct NoctisTerminalApp: SwiftTUIRuntime.App {
    let state: ConversationUIState

    nonisolated init() {
        fatalError("NoctisTerminalApp must be launched with an injected conversation state")
    }

    init(state: ConversationUIState) {
        self.state = state
    }

    var body: some Scene {
        WindowGroup("Noctis") {
            ConversationView(state: state)
        }
    }
}

struct ConversationView: View {
    @Bindable var state: ConversationUIState
    @Environment(\.requestTermination) private var requestTermination

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            VStack(alignment: .leading) {
                Text("✦ Noctis").bold()
                Text("Assistant personnel · IA locale").foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if state.messages.isEmpty {
                        Text("Comment puis-je t’aider ?").paragraph()
                    }
                    ForEach(state.messages) { message in
                        MessageView(message: message)
                    }
                    if let interface = state.interface {
                        DynamicComponentHost(node: interface.root) { nodeID, actionID in
                            state.messages.append(.init(id: UUID(), role: .user,
                                                        text: "Action \(actionID) sur \(nodeID)"))
                        }
                        .id(interface.revision)
                    }
                    if let error = state.interfaceError {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            Divider()
            HStack {
                Text("❯")
                TextField("Écris à Noctis", text: $state.prompt)
                    .onSubmit {
                        let command = state.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        if command == "/exit" || command == "exit" { _ = requestTermination() }
                        else { state.submit() }
                    }
                if state.isGenerating {
                    Button("Interrompre") { state.cancel() }
                }
            }
        }
        .padding(1)
    }
}

private struct MessageView: View {
    let message: ConversationUIState.Message

    var body: some View {
        VStack(alignment: .leading) {
            Text(message.role == .user ? "Vous" : "✦ Noctis").bold()
            Text(message.text.isEmpty ? "…" : message.text).paragraph()
        }
    }
}

struct DynamicComponentHost: View {
    let node: InterfaceNode
    let onAction: @MainActor @Sendable (String, String) -> Void

    @ViewBuilder var body: some View {
        switch node.type {
        case .row:
            HStack { children }
        case .divider:
            Divider()
        case .progress:
            ProgressView(value: number("value") ?? 0)
        case .heading:
            Text(string("value")).bold()
        case .text, .markdown, .status:
            Text(string("value")).paragraph()
        case .choice, .confirmation, .menu:
            VStack(alignment: .leading) {
                if !string("title").isEmpty { Text(string("title")).bold() }
                ForEach(node.actions) { action in
                    Button(action.label) { onAction(node.id, action.id) }
                }
                children
            }
        default:
            VStack(alignment: .leading) {
                if !string("title").isEmpty { Text(string("title")).bold() }
                children
            }
        }
    }

    @ViewBuilder private var children: some View {
        ForEach(node.children, id: \.id) { child in
            DynamicComponentHost(node: child, onAction: onAction)
        }
    }

    private func string(_ key: String) -> String {
        guard case .string(let value) = node.properties[key] else { return "" }
        return value
    }

    private func number(_ key: String) -> Double? {
        guard case .number(let value) = node.properties[key] else { return nil }
        return value
    }
}
