// Created by Sébastien DAGUIN

/// Selected by the host client, independently of the execution platform.
public enum NoctisPresentationInstructions: Sendable {
    case plainText
    case markdown

    var text: String {
        switch self {
        case .plainText:
            """
            PRÉSENTATION
            Utilise du texte brut et des paragraphes courts, sans syntaxe Markdown.
            Affiche directement les URL. N'utilise ni titres #, ni gras **,
            ni liens ou tableaux Markdown.
            """
        case .markdown:
            """
            PRÉSENTATION
            Adapte la structure à la demande. Le client accepte du Markdown simple :
            paragraphes, listes, emphase, liens et blocs de code si utiles.
            N'utilise pas de HTML ou de contenu interactif non pris en charge.
            """
        }
    }
}
