// Created by Sébastien DAGUIN
import Foundation

/// Routes explicit research requests before generation. AgentLoop still owns execution and permissions.
enum FoundationModelsWebSearchPolicy {
    static func proposedCall(
        messages: [ChatMessage], tools: [ToolDefinition], existingCallIDs: Set<String>,
        date: Date = Date(), timeZone: TimeZone = .current
    ) throws -> ToolCall? {
        guard let search = tools.first(where: { $0.name == WebSearchTool.name }),
              let currentIndex = messages.lastIndex(where: isUser),
              let current = userText(messages[currentIndex]),
              !messages.suffix(from: currentIndex + 1).contains(where: isSearchResult),
              let source = searchRequest(current, previous: previousUser(before: currentIndex, in: messages)) else {
            return nil
        }
        let query = boundedQuery(source, date: date, timeZone: timeZone)
        guard !query.isEmpty else { return nil }
        let arguments = JSONValue.object(["query": .string(query)])
        guard FoundationModelsBridge.matches(arguments, schema: search.parametersSchema) else { return nil }
        var id = FoundationModelsBridge.makeCallID()
        while existingCallIDs.contains(id) { id = FoundationModelsBridge.makeCallID() }
        return ToolCall(id: id, name: search.name, arguments: try FoundationModelsBridge.json(arguments))
    }

    private static func searchRequest(_ current: String, previous: String?) -> String? {
        let text = normalized(current)
        // Inspect the complete request before bounding it, including a trailing opt-out.
        guard !excludesAutomaticSearch(text), !isTextTransformation(text) else { return nil }
        if isSubjectlessWebRequest(text) {
            guard let previous else { return nil }
            let prior = normalized(previous)
            guard !excludesAutomaticSearch(prior), !isTextTransformation(prior),
                  !isSubjectlessWebRequest(prior), isIsolatedRequest(previous), needsSearch(prior) else { return nil }
            return previous
        }
        return isIsolatedRequest(current) && needsSearch(text) ? current : nil
    }

    private static func needsSearch(_ text: String) -> Bool {
        let explicitSearch = matches(text,
            #"\b(?:cherche|cherchez|chercher|recherche|recherchez|rechercher|search|browse)\b"#
                + #".{0,100}\b(?:web|internet|online)\b"#)
            || matches(text, #"\b(?:utilise|utiliser|use|using)\b.{0,30}\bweb search\b"#)
            || matches(text,
                #"^(?:(?:s il te plait|please) )?(?:cherche|cherchez|recherche|recherchez|search for|search|browse|"#
                    + #"find sources|trouve des sources)\b"#)
            || matches(text,
                #"\b(?:fais|faire|effectue|effectuer|do|perform)\b.{0,25}\b(?:une recherche|a search)\b"#)
        let news = matches(text, #"\b(?:news|actualite|actualites|nouveautes)\b"#)
            || matches(text, #"\b(?:dernieres nouvelles|latest updates|breaking news)\b"#)
        let currentFact = matches(text,
            #"\b(?:aujourd hui|du jour|today|current|currently|latest|recent|recente|recents|recentes|actuel|"#
                + #"actuelle|actuels|actuelles|derniere|dernieres|dernier|derniers)\b"#)
            && matches(text,
                #"\b(?:version|versions|prix|price|prices|tarif|tarifs|cours|meteo|weather|score|scores|"#
                    + #"resultat|resultats|president|ceo|disponibilite|availability|annonce|annonces|"#
                    + #"release|releases|nouvelles)\b"#)
        return explicitSearch || news || currentFact
    }

    private static func excludesAutomaticSearch(_ text: String) -> Bool {
        matches(text,
            #"\b(?:sans|without)\b.{0,50}\b(?:web|internet|recherche|recherches|chercher|search|"#
                + #"searching|browsing|browse|online)\b"#)
            || matches(text,
                #"\b(?:ne|n)\b.{0,50}\b(?:pas|jamais)\b.{0,40}\b(?:web|internet|reseau|recherche|chercher)\b"#)
            || matches(text,
                #"\b(?:ne|n)\b.{0,15}\b(?:cherche\w*|recherch\w*|consult\w*|utilis\w*)\b"#
                    + #".{0,30}\b(?:pas|jamais)\b"#)
            || matches(text,
                #"\b(?:pas de recherche|aucune recherche|do not search|don t search|do not browse|"#
                    + #"don t browse|no web search|no internet)\b"#)
            || matches(text, #"\b(?:hors ligne|offline)\b"#)
    }

    private static func isTextTransformation(_ text: String) -> Bool {
        matches(text,
            #"\b(?:traduis|traduire|traduisez|traduction|translate|translation|reformule|reformuler|reformulez|"#
                + #"rephrase|rewrite|corrige|corriger|corrigez|proofread|recopie|repete|repeat|quote)\b"#)
            || matches(text,
                #"\b(?:cite exactement|ecris exactement|write exactly|copy exactly|resume ce texte|"#
                    + #"resume cette phrase|summarize this text|summarise this text|explique comment utiliser|"#
                    + #"explique comment fonctionne|comment faire une recherche|comment utiliser|"#
                    + #"how to search|how do i search|how to use|explain how to|que signifie|what does)\b"#)
    }

    private static func isIsolatedRequest(_ source: String) -> Bool {
        // A mixed or long message may include context that must not become a network query.
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.count <= 300, source.utf8.count <= 1_200,
              !(trimmed.hasPrefix("'") && trimmed.hasSuffix("'")),
              !source.contains(where: { ",;:\n\r`«»“”\"".contains($0) }),
              !matches(source, #"[.!?]\s+\S"#) else { return false }
        return matches(normalized(source),
            #"^(?:(?:bonjour|salut|hello|please|s il te plait) )?(?:fais|donne|montre|presente|resume|prepare|"#
                + #"explique|quel|quelle|quels|quelles|cherche|chercher|cherchez|recherche|recherchez|"#
                + #"peux tu|tu peux|pouvez vous|pourrais tu|je veux|je voudrais|j aimerais|dis moi|"#
                + #"actualite|actualites|news|nouveautes|give|show|summarize|summarise|search|browse|find|"#
                + #"what|which|latest|current|can you|could you|i want|i would like)\b"#)
    }

    private static func isSubjectlessWebRequest(_ text: String) -> Bool {
        let words = Set(text.split(separator: " ").map(String.init))
        let webWords: Set<String> = ["web", "internet", "online", "browse", "browsing", "recherche", "search"]
        let requestWords: Set<String> = [
            "tu", "vous", "peux", "peut", "pouvez", "pourrais", "pourriez", "faire", "fais", "effectuer",
            "une", "un", "la", "le", "les", "des", "de", "du", "sur", "internet", "web", "search",
            "recherche", "recherches", "utiliser", "utilise", "chercher", "cherche", "rechercher",
            "acces", "as", "avez", "a", "au", "est", "ce", "que", "et", "en", "ligne", "l", "outil", "outils",
            "can", "could", "you", "do", "the", "use", "to", "for", "please", "svp", "stp", "tool", "tools",
            "access", "have", "bien", "vraiment", "actually", "really",
            "s", "il", "te", "plait", "browsing", "browse", "online", "maintenant", "now", "alors"
        ]
        return !words.isDisjoint(with: webWords) && words.isSubset(of: requestWords)
    }

    private static func boundedQuery(_ source: String, date: Date, timeZone: TimeZone) -> String {
        let separators = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        let text = source.components(separatedBy: separators).filter { !$0.isEmpty }.joined(separator: " ")
        let suffix: String
        if matches(normalized(source), #"\b(?:aujourd hui|du jour|today)\b"#) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            suffix = " " + formatter.string(from: date)
        } else {
            suffix = ""
        }
        var query = ""
        var bytes = 1_200 - suffix.utf8.count
        for character in text.prefix(300 - suffix.count) {
            let size = String(character).utf8.count
            guard size <= bytes else { break }
            query.append(character)
            bytes -= size
        }
        query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? "" : query + suffix
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func previousUser(before index: Int, in messages: [ChatMessage]) -> String? {
        guard let previous = messages[..<index].lastIndex(where: isUser),
              !messages[(previous + 1)..<index].contains(where: isSearchResult) else { return nil }
        return userText(messages[previous])
    }

    private static func isUser(_ message: ChatMessage) -> Bool {
        switch message {
        case .user, .userMultimodal: true
        default: false
        }
    }

    private static func userText(_ message: ChatMessage) -> String? {
        switch message {
        case let .user(text): return text
        case let .userMultimodal(parts):
            var text: [String] = []
            for part in parts {
                guard case let .text(value) = part else { return nil }
                text.append(value)
            }
            return text.joined(separator: "\n")
        default: return nil
        }
    }

    private static func isSearchResult(_ message: ChatMessage) -> Bool {
        if case let .tool(_, name, _) = message { return name == WebSearchTool.name }
        return false
    }
}
