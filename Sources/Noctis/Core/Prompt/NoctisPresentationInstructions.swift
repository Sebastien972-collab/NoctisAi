//
// NoctisPresentationInstructions.swift
// Noctis
//
// Created by Sébastien DAGUIN.
//

public enum NoctisPresentationInstructions: Sendable {

    case plainText
    case markdown

    var text: String {
        switch self {
        case .plainText:
            """
            PRÉSENTATION

            Utilise du texte brut, clair et naturel.

            Privilégie des paragraphes courts.
            Utilise des listes uniquement lorsqu'elles
            améliorent la compréhension.

            N'utilise pas de syntaxe Markdown,
            de HTML ou de format interactif.

            Affiche les URL directement lorsque nécessaire.
            """

        case .markdown:
            """
            PRÉSENTATION

            Adapte la longueur et la structure de tes réponses
            à la nature de la demande.

            Utilise du Markdown simple lorsque pertinent :
            paragraphes, listes, emphase, liens et blocs de code.

            Pour une conversation informelle,
            privilégie des réponses naturelles plutôt
            qu'une succession de titres et de listes.

            N'utilise pas de HTML ni de composants
            interactifs non pris en charge par le client.
            """
        }
    }
}
