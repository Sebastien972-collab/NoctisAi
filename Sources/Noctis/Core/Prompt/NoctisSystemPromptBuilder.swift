// Created by Sébastien DAGUIN

enum NoctisSystemPromptBuilder {
    static func build(
        registry: NoctisToolRegistry,
        context: NoctisRuntimeContext = NoctisRuntimeContext(),
        presentation: NoctisPresentationInstructions = .markdown
    ) -> String {
        [
            NoctisIdentity.text,
            NoctisCoreInstructions.text,
            NoctisSecurityInstructions.text,
            NoctisToolInstructions.text(registry: registry),
            context.text(registry: registry),
            presentation.text
        ].joined(separator: "\n\n")
    }
}
