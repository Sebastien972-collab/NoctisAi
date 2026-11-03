# Audit et sécurisation Web — 3 novembre 2026

## A. Audit initial

État Git initial propre, HEAD `f50aa58`. Aucun commit créé. Les fichiers réellement présents ont été examinés : manifeste et verrou SwiftPM, services, protocoles, modèles, erreurs, dispatcher, schéma MLX, initialisation ChatSession, instructions système, tests, compose et configuration SearXNG.

Le chemin actif est `ChatSession → web_search → WebToolDispatcher → SearXNGService → URLSession`. Le service de pages existait mais aucun schéma ni branche opérationnelle `web_open` n'était exposé au modèle.

| Criticité | Constat initial | Impact |
| --- | --- | --- |
| Critique, latente | HTTPWebPageService accepte HTTP/HTTPS arbitraires, sans politique de destination et avec redirections automatiques | Accès aux services locaux, métadonnées cloud et réseaux privés dès son exposition |
| Critique, latente | Aucun contrôle de l'adresse effectivement connectée | DNS rebinding ; un précontrôle DNS laisserait une fenêtre TOCTOU |
| Élevée | `data(for:)` dans les deux services, sans plafond | Téléchargements et allocations non bornés, réponses compressées |
| Élevée | Sessions partagées, redirections et stockage implicites | Cookies, authentification ou requêtes pouvant sortir du périmètre attendu |
| Élevée | Requêtes imprimées, erreurs réseau remontées sans filtrage | Divulgation de requêtes et détails réseau |
| Élevée | Résultats externes sans enveloppe de confiance | Prompt injection et appels d'outils induits ; le prompt ne constitue pas une protection |
| Modérée | MIME vérifié par sous-chaîne, UTF-8 seul, pas de plafond DOM | Confusion de contenu, incompatibilités, consommation CPU |
| Modérée | Tests Web presque absents ; test SearXNG réel optionnel | Garanties non démontrées |
| Résiduelle | MLX sur main verrouillé par révision, image SearXNG latest et montage de configuration inscriptible | Surveillance de chaîne d'approvisionnement et du service local nécessaire |

## B. Modifications réalisées

Chemins relatifs au dépôt.

| Fichier | Changement, problème résolu et compromis |
| --- | --- |
| `Package.swift` | Ajoute SafeURLKit exactement 0.2.0. Centralise le parsing sensible sans réimplémenter les variantes IP. Nouvelle dépendance limitée à Foundation. |
| `Package.resolved` | Verrouille la révision SafeURLKit ; aucune version des autres dépendances changée. |
| `Sources/Noctis/Features/Web/Domain/PublicWebURLPolicy.swift` | Validation de la chaîne brute via URLPolicy stricte ; erreurs normalisées. HTTPS/443, pas d'identifiants, noms spéciaux, IP littérales, fragments non vides ou chaînes ambiguës. Plafond de 2048 octets. Refuse aussi les IP publiques et les noms de documentation : restriction volontaire. Ne valide pas DNS. |
| `Sources/Noctis/Features/Web/Data/BoundedHTTPClient.swift` | Transport interne dédié, session éphémère par requête, sans cookies, cache, stockage d'identifiants ni proxy configuré. Refuse toute redirection et authentification autre que l'évaluation TLS standard. Vérifie statut, MIME exact, URL finale, longueur déclarée et octets reçus. Refuse 206. État protégé par Mutex, annulation et continuation unique. Aucun @unchecked Sendable ajouté au code Noctis. |
| `Sources/Noctis/Features/Web/Data/HTTPWebPageService.swift` | `open` refuse toute ouverture publique après validation, sans DNS ni connexion. Préserve le protocole et l'extraction hors réseau : titre, URL, Unicode, troncature et texte principal. HTML/XHTML seulement ; UTF-8 par défaut, ASCII et Windows-1252/Latin-1 explicitement déclarés. Refuse encodages inconnus, contenu vide et parsing inexploitable. Le paramètre session a été retiré car il permettait un transport incontrôlé. |
| `Sources/Noctis/Features/Web/Domain/Enum/WebPageError.swift` | Erreurs exploitables sans URL ni diagnostics sensibles : taille, compression, redirection, timeout, configuration, transport, absence de contenu et ouverture désactivée. |
| `Sources/Noctis/Features/Web/Domain/Repository/SearXNGService.swift` | Seul l'endpoint configuré HTTP 127.0.0.1:port/search est accepté. Ni DNS, ni host/path/query choisis par le modèle. Le port reste configurable par le programme. JSON obligatoire, requêtes bornées et correctement encodées. Injection URLProtocol pour tests à la place d'une session partagée. Une instance distante ou un reverse proxy redirigeant n'est plus accepté. |
| `Sources/Noctis/Features/Web/Domain/Tools/WebToolDispatcher.swift` | Vérifie exactement les arguments attendus, 300 caractères et 1200 octets de requête, sans caractères de contrôle. Retire les logs et masque les erreurs inconnues. Enveloppe JSON UNTRUSTED_EXTERNAL_DATA ; cinq résultats au maximum, parmi les cinquante premiers examinés. URL filtrées, titres limités à 512 caractères/2048 octets, descriptions à 2000 caractères/8000 octets. Les graphèmes Unicode géants ne contournent pas le plafond d'octets. `web_open` valide puis refuse, même avec un service injecté. Le paramètre historique `pasgeService` est conservé pour compatibilité. |
| `Sources/Noctis/Core/Enum/NoctisIdentity.swift` | Ajoute les règles de traitement des données externes et de confidentialité. Aucun changement du moteur MLX ou de ses capacités. Ces instructions ne sont pas une frontière de sécurité. |
| `Tests/NoctisTests/WebSecurityTests.swift` | Matrice URL, blocage public et annulation, refus des redirections, arguments, enveloppe JSON, erreurs expurgées et budget Unicode. |
| `Tests/NoctisTests/BoundedHTTPClientTests.swift` | URLProtocol sans état global mutable : succès, statuts, MIME, tailles, Content-Length, compression, URL finale inattendue, interruption, timeout, annulation et isolation SearXNG. Aucune requête réelle. |
| `Tests/NoctisTests/WebExtractionTests.swift` | Article, titre absent, HTML malformé/vide, absence de contenu, Unicode, encodage Windows-1252, limite exacte et troncature. |
| `Tests/NoctisTests/WebTransportIntegrationTests.swift` | Serveur Network.framework créé par le test sur un port loopback éphémère : chunked normal et excessif, redirection jamais suivie, réponse partielle, timeout inactif, deadline globale malgré un flux continu, annulation et JSON SearXNG. Aucun service privé existant contacté. |
| `WEB_SECURITY.md` | Ce rapport et les critères de réactivation. |

### Limites effectives

- Corps accumulé : 2 Mio par requête, configurable à la baisse ; l'excédent est rejeté avant ajout au buffer et la tâche est annulée.
- Timeout d'inactivité/requête : 15 secondes ; durée de ressource : 30 secondes ; valeurs positives finies configurables.
- Redirections : **zéro**, fixé intentionnellement. Une redirection publique, une boucle et un saut privé sont tous refusés au premier saut. Aucun test ne prétend autoriser une redirection publique.
- Compression : demande `Accept-Encoding: identity`, refuse tout Content-Encoding autre qu'identity avant d'autoriser le corps. Cette restriction de compatibilité évite d'introduire un décompresseur.
- Extraction : 2 Mio d'entrée hors réseau, 20 000 éléments Readability, 20 000 caractères de texte maximum (configurable à la baisse), titre de 512 caractères.
- Les octets réseau, le nombre d'éléments DOM et les caractères transmis sont des limites distinctes.

SwiftReadability 0.3.3 a été inspecté dans le checkout résolu. `Readability(html:url:options:)`, `parse()`, `ReadabilityResult.textContent` et `maxElemsToParse` sont des API réelles. Les deux extensions restent actives : imageCarouselRecovery transforme des galeries identifiées en figures ; publisherChromeCleanup retire des éléments éditoriaux parasites. Elles modifient le DOM et peuvent influencer les heuristiques de sélection ou supprimer du texte légitime. Elles ne chargent pas les images, ne lancent pas JavaScript et n'effectuent pas de requêtes réseau dans le code inspecté.

## C. Dépendances et choix du transport

SafeURLKit **0.2.0**, révision **e9c4eddcfd3e16669a19f46142f487d9b74fbc14**. Tags distants, manifeste Swift 6.2+, code URLPolicy, parsing, noms réservés et delegate de redirection examinés. Aucun audit indépendant de cette jeune bibliothèque n'est supposé.

Références :
- [Source de la version utilisée](https://github.com/adamtheturtle/SafeURLKit/tree/0.2.0)
- [Politique et limites DNS](https://github.com/adamtheturtle/SafeURLKit/blob/0.2.0/Sources/SafeURLKit/URLPolicy.swift)
- [Delegate de redirection étudié](https://github.com/adamtheturtle/SafeURLKit/blob/0.2.0/Sources/SafeURLKit/PolicyEnforcingRedirectDelegate.swift)
- [SwiftReadability 0.3.3](https://github.com/wolfyy970/swift-readability/tree/0.3.3)
- [Delegate URLSession et redirections](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate)

Le delegate SafeURLKit revalide les redirections et retire certains en-têtes lors d'un changement d'origine. Il ne contrôle pas la connexion DNS effective et ne fournit pas notre budget de sauts. Il déclare lui-même @unchecked Sendable ; Noctis ne l'instancie pas. Notre delegate vérifié Sendable refuse tous les sauts.

Une résolution DNS préalable suivie de `URLSession` serait insuffisante. Les métriques de connexion sont trop tardives pour empêcher une requête. Un transport public correct doit connecter l'adresse validée tout en préservant Host, SNI et validation TLS, gérer toutes les familles d'adresses, redirections, proxies et reconnexions. Réécrire ces couches autour de Network.framework ne serait pas un correctif raisonnablement vérifiable ici.

Une passerelle de sortie isolée et auditée serait une autre solution, à condition d'interdire tout chemin de contournement et de vérifier les destinations après résolution. Aucune passerelle de ce type n'existe dans le dépôt. Aucun faux mode « sécurisé » ou flag d'activation n'a donc été ajouté : le blocage est le mécanisme de sécurité effectivement livré.

Les dépendances existantes restent inchangées : SwiftReadability 0.3.3, SwiftSoup 2.13.6, swift-url 0.4.2 transitif, ainsi que les dépendances MLX/HuggingFace et leurs révisions verrouillées.

## D. Validation réellement effectuée

- `swift package resolve`, `swift build` et `swift test` lancés : échec initial du sandbox imbriqué, `sandbox-exec: sandbox_apply: Operation not permitted`.
- `swift package --disable-sandbox resolve` : **réussi**. Avertissements de caches SwiftPM non inscriptibles ; aucune dépendance existante mise à jour.
- `swift build --disable-sandbox` : **réussi**. Avertissements C++17 dans le code Metal généré de MLX, hors module Web.
- `swift test --disable-sandbox` : compilation atteinte mais signature du bundle de tests refusée à cause d'attributs Finder/FileProvider dans .build. Nettoyage ciblé de FinderInfo tenté ; la reconstruction les réintroduit. **Ne pas considérer cette commande comme un succès.**
- BuildProject Xcode, y compris les cibles de tests : **réussi**. Pas d'erreur Swift Concurrency ; avertissement de métadonnées AppIntents sans framework associé.
- RunAllTests Xcode sur la version finale du code : **100 cas, 99 réussis, 0 échec, 1 ignoré**.
- Le cas ignoré est le test préexistant nécessitant RUN_SEARXNG_TESTS=1 et une vraie instance. La compatibilité du client est vérifiée avec URLProtocol et le serveur contrôlé ; la disponibilité de l'instance Docker réelle et de ses moteurs n'est pas affirmée.
- Diff relu et vérification de whitespace effectuée. Aucun secret réel identifié dans les ajouts ; identifiants présents uniquement sous forme de chaînes factices de tests. Aucun commit.

Les tests simulés ne prouvent ni DNS rebinding ni enforcement de l'adresse du pair. L'intégration utilise HTTP loopback contrôlé pour vérifier les garanties du transport interne, pas un réseau public ou une attaque DNS réelle.

## E. Sécurité résiduelle

1. **DNS rebinding / TOCTOU** : non résolus pour les URL publiques ; neutralisés pour l'outil par l'interdiction de toute connexion publique. Ne pas brancher BoundedHTTPClient sur web_open : il ne constitue pas un transport SSRF sûr.
2. **Prompt injection** : JSON et instructions réduisent la confusion, sans garantir le comportement du modèle. Les actions sensibles doivent rester contrôlées dans le code. web_open reste bloqué indépendamment des instructions.
3. **Confidentialité des recherches** : seul query est transmis, sans ajout automatique de contexte, cookie ou identifiant. Un modèle peut toutefois recopier une information personnelle dans query. Il n'existe pas de détection sémantique fiable des secrets ni de consentement par recherche dans cette livraison. SearXNG et ses moteurs reçoivent les recherches ; leurs propres logs et sorties ne sont pas contrôlés par ce client.
4. **Ressources** : le plafond de 2 Mio concerne le buffer applicatif, pas toute la mémoire de Foundation, du noyau ou du parseur. Les en-têtes et buffers internes appartiennent à URLSession. Le parsing HTML synchrone n'est pas interrompu au milieu d'un appel ; la limite DOM est appliquée par Readability après création du document. Pas de plafond global de mémoire sur plusieurs requêtes concurrentes.
5. **Compression** : les en-têtes compressés sont refusés ; cela ne prouve pas un plafond strict du CPU et des buffers internes de CFNetwork. Aucun serveur public hostile n'est accessible via le service de pages.
6. **Encodages** : pas de détection heuristique des charset de balises meta, ni prise en charge universelle des pages anciennes. Les contenus non décodables sont refusés.
7. **Service local** : l'instance SearXNG et la machine hôte sont de confiance. Un processus local malveillant occupant le port configuré pourrait falsifier les résultats. La politique publique n'hérite jamais de cette exception locale.
8. **Chaîne d'approvisionnement** : mises à jour des tables SafeURLKit à surveiller ; absence de garantie d'audit indépendant. L'image Docker latest, les privilèges réseau du conteneur et sa configuration modifiable restent à durcir séparément avant un déploiement non local.

## F. État de préparation

**NON PRÊT pour activer web_open sur des URL arbitraires générées par Ministral.**

La faille critique n'est pas masquée par une validation syntaxique : l'ouverture est désactivée dans le service et le dispatcher, et son schéma n'est pas annoncé à MLX. La recherche interne et l'extraction hors réseau sont conservées et testées.

Pour lever le blocage : fournir un transport ou proxy qui impose l'adresse effective validée, tester DNS changeant, IPv4/IPv6, redirections, reconnexions, TLS/SNI et impossibilité de contourner le proxy, puis définir la politique de consentement/confidentialité des sorties avant activation. Une simple modification du prompt, une liste de noms ou une résolution DNS avant URLSession ne suffisent pas.
