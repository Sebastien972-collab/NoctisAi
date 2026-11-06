<!-- Created by Sébastien DAGUIN -->

# Noctis 🌙

Noctis est un assistant IA personnel en ligne de commande, développé en Swift pour macOS. Il utilise **Ministral 3 14B Instruct**, au format MLX quantifié sur 4 bits, pour générer ses réponses localement et les afficher progressivement dans le terminal.

Le projet comprend une conversation en streaming et un outil `web_search` connecté à SearXNG. La mémoire persistante et une API Vapor ne sont pas encore implémentées.

Le package expose la bibliothèque `Noctis`, importable dans une application, et l’exécutable `NoctisCLI` pour le terminal.

## Localisation

Le français est la langue de référence (`defaultLocalization: "fr"`) ; l’anglais est
également disponible. Chaque target utilise un seul `Resources/Localizable.xcstrings`
et son propre `Bundle.module` : erreurs pour `Noctis`, messages du terminal pour `NoctisCLI`.

Utiliser des clés sémantiques hiérarchiques en snake_case, jamais le texte affiché :
`error.network.timeout`, `console.status.ready`, `console.error.details`.
Dans ce package Foundation, écrire la clé littérale avec sa valeur française et un commentaire :

```swift
String(
    localized: "error.network.timeout",
    defaultValue: "Le délai de la requête Web est dépassé.",
    bundle: .module,
    comment: "La requête Web a dépassé le délai autorisé."
)
```

Conserver les variables dans `defaultValue` par interpolation native, sans concaténation.
Pour une quantité, utiliser les variantes de pluriel du catalogue ; un code de sortie
n’est pas une quantité et ne nécessite pas de pluriel.
Compiler dans Xcode pour extraire les nouvelles clés, puis vérifier les valeurs françaises
et anglaises dans les catalogues. Les instructions du modèle, les identifiants techniques
et les commandes comme `exit` ne sont pas traduits.
L’application hôte doit déclarer les langues prises en charge. Les previews SwiftUI et
la validation visuelle de Fullmoon se font dans son dépôt hôte.

## Fonctionnalités présentes

- Chargement d’un modèle depuis son identifiant Hugging Face avec MLX Swift LM.
- Initialisation d’une session `ChatSession` avec l’identité et les instructions de Noctis.
- Réutilisation de cette session pendant les échanges du processus courant.
- Lecture de prompts dans le terminal et affichage des fragments au fil de leur réception.
- Suppression des espaces autour des prompts et omission des messages vides.
- Arrêt avec `exit`, quelle que soit la casse, ou à la fermeture de l’entrée standard.
- Affichage des erreurs de chargement, de génération et de lecture du flux.
- Recherche Web via `web_search`, `WebToolDispatcher` et le service SearXNG local.

L’inférence est locale. Le chargeur recherche d’abord une installation complète dans le cache
Hugging Face avec `localFilesOnly: true`, sans vérification réseau. Si des fichiers manquent, le
client Hugging Face télécharge les éléments nécessaires en réutilisant le cache. Les fichiers du
tokenizer et tous les shards de poids doivent être présents ; les index hérités d’un modèle non
quantifié sont acceptés lorsque le jeu de shards quantifiés est complet. Un modèle installé peut
être rechargé sans réseau. Les outils Web restent dépendants de leurs propres services.

## Prérequis

- **Swift 6.4 ou ultérieur**, conformément à `swift-tools-version` dans `Package.swift`.
- **macOS 15 ou ultérieur**, minimum déclaré par le package.
- Un Mac compatible avec MLX et Metal, avec une capacité mémoire adaptée à l’exécution du modèle 14B choisi. Cette version ne fournit pas de mesure de consommation mémoire ni de benchmark matériel.
- Xcode et son **composant Metal Toolchain** pour compiler les shaders des dépendances MLX.
- Un accès réseau pour récupérer les packages Swift et, lors d’un premier lancement réel, les fichiers du modèle s’ils ne sont pas déjà disponibles dans le cache du chargeur.

L’installation des outils et du composant Metal est à effectuer dans votre environnement. Voir la [documentation Apple sur les composants Xcode](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components).

## Démarrer

Depuis la racine du dépôt :

```sh
swift --version
swift package resolve
swift build
swift run NoctisCLI
```

`swift run NoctisCLI` lance réellement l’assistant : son point d’entrée instancie `MLXModelService`, puis appelle `NoctisApplication.run()`. Cette commande peut donc provoquer le téléchargement et le chargement du modèle. Elle n’est pas utilisée par les tests unitaires.

Une fois le message `Tout est prêt !` affiché, saisir une question après `Vous >`. Les réponses sont affichées après `Noctis 🌙 >`. Saisir `exit` pour terminer.

Pour une compilation optimisée :

```sh
swift build -c release
swift run -c release NoctisCLI
```

Aucun argument de ligne de commande ni fichier de configuration utilisateur n’est actuellement interprété par le programme.

## Configuration

Les valeurs actuelles sont définies dans [NoctisConfiguration.swift](Sources/Noctis/Core/Configuration/NoctisConfiguration.swift) :

| Propriété | Valeur | Rôle |
| --- | --- | --- |
| `modelID` | `mlx-community/Ministral-3-14B-Instruct-2512-4bit` | Modèle utilisé par le chargeur MLX |
| `assistantName` | `Noctis` | Nom affiché au démarrage |
| `exitCommand` | `exit` | Commande de sortie de la conversation |

Le prompt système se trouve dans [NoctisIdentity.swift](Sources/Noctis/Core/Enum/NoctisIdentity.swift). Il décrit l’identité, le ton, les capacités actuelles et les règles de comportement de l’assistant. Il est transmis à `ChatSession` lors du chargement du modèle.

Modifier ces constantes ou les instructions nécessite une recompilation. Aucun choix dynamique du modèle ou du prompt système n’est prévu dans l’interface actuelle.

## Organisation du code

```text
Sources/
├── Noctis/
│   ├── Features/Web/              # Services, outils et lecture de pages Web
│   └── Core/
│       ├── AI/
│       │   ├── AIModelService.swift
│       │   ├── MLXModelService.swift
│       │   └── ModelSessionWorker.swift
│       ├── Configuration/
│       │   └── NoctisConfiguration.swift
│       └── Enum/
│           ├── MLXModelServiceError.swift
│           └── NoctisIdentity.swift
└── NoctisCLI/
    ├── NoctisCLI.swift
    ├── Domain/
    │   └── NoctisApplication.swift
    └── Interface/
        └── ConsoleInterface.swift
Tests/
└── NoctisTests/
    ├── HTTPWebPageServiceTests.swift
    ├── MLXModelServiceTests.swift
    ├── MockAIModelService.swift
    ├── NoctisApplicationTests.swift
    ├── NoctisTests.swift           # ModelConcurrencyTests
    └── SearXNGServiceTests.swift
```

| Élément | Responsabilité réelle |
| --- | --- |
| `Noctis` | Bibliothèque contenant le moteur IA et les outils Web |
| `NoctisCLI` | Point d’entrée asynchrone ; assemble l’application console avec le moteur de la bibliothèque |
| `NoctisApplication` | Charge le moteur injecté, lit et filtre les entrées, consomme les flux et affiche les erreurs |
| `AIModelService` | Contrat d’inférence `Sendable` : chargement, génération, consommation et annulation |
| `MLXModelService` | Acteur qui coordonne le chargement et réserve une seule génération à la fois |
| `ModelSessionWorker` | Crée et utilise la session mutable dans sa tâche de travail et attend son nettoyage |
| `ConsoleInterface` | Regroupe des méthodes de console ; cette structure n’est pas encore utilisée par `NoctisApplication` |
| `NoctisConfiguration` | Constantes de configuration compilées avec l’application |
| `NoctisIdentity` | Instructions système transmises à la session |

Les dossiers `Noctis` et `NoctisCLI` constituent **deux modules distincts**. La cible exécutable `NoctisCLI` dépend de la bibliothèque `Noctis` et l’utilise avec `import Noctis`. Les dépendances MLX et Web sont déclarées dans la bibliothèque ; la console dépend uniquement de `Noctis`.

**Il n’existe pas de `ChatService` dans cette révision.** La gestion des échanges est portée par `NoctisApplication`. Les tests couvrent ce code existant ; aucun service ni découpage supplémentaire n’a été ajouté pour les besoins des tests.

## Contrat du moteur et cycle d’une conversation

Le protocole `AIModelService` expose :

```swift
func load() async throws
func load(progress: @escaping @Sendable (AIModelLoadPhase) -> Void) async throws
func resetConversation(history: [AIChatMessage]) async throws
func cancelGeneration() async
func withResponse(
    prompt: String,
    consume: @Sendable (AsyncThrowingStream<String, Error>) async throws -> Void
) async throws
func generate(prompt: String) async throws -> AsyncThrowingStream<String, Error>
```

1. `NoctisApplication` reçoit son moteur par injection de constructeur.
2. `run()` appelle `load()` avant d’accepter les échanges.
3. `MLXModelService.load()` charge le modèle et crée une `ChatSession` avec le prompt système.
4. Chaque message non vide, après suppression des espaces périphériques, est transmis à `withResponse(prompt:consume:)`.
5. L’application lit le flux avec `for try await` et imprime chaque fragment immédiatement.
6. La même instance du moteur est utilisée pour les messages suivants ; la boucle ne rappelle pas `load()` à chaque échange.

Deux moments d’échec sont possibles lors de la génération :

- **Avant de retourner un flux** : la demande asynchrone peut échouer. L’implémentation MLX lève `MLXModelServiceError.modelNotLoaded` si aucune session n’a été chargée et `generationInProgress` si une génération est déjà réservée.
- **Pendant la consommation du flux** : l’itération asynchrone peut lever une erreur après zéro ou plusieurs fragments. Les fragments déjà affichés restent visibles.

L’application affiche ces erreurs puis accepte le message suivant. Un échec initial de `load()` interrompt au contraire le démarrage de la conversation. `run()` affiche l’erreur et termine normalement : il ne la propage pas à son appelant.

`withResponse` attend aussi le nettoyage de la génération après consommation, erreur ou annulation. Les tests de concurrence existants vérifient ces transitions avec des sessions simulées.

## Dépendances

Le manifeste déclare les packages suivants :

| Package | Produits directement utilisés par la cible |
| --- | --- |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | `MLXLMCommon`, `MLXVLM`, `MLXHuggingFace` |
| [swift-huggingface](https://github.com/huggingface/swift-huggingface) | `HuggingFace` |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | `Tokenizers` |
| [SwiftSoup](https://github.com/scinfu/SwiftSoup) | `SwiftSoup`, utilisé pour extraire le texte des pages HTML |

`Package.resolved` enregistre les révisions exactes, y compris celle du package `mlx-swift-lm` déclaré sur la branche `main`. Conserver ce fichier permet de partager les mêmes révisions entre développeurs.

La présence de `MLXVLM` dans les dépendances ne constitue pas une interface de saisie d’images : la CLI actuelle transmet uniquement des prompts textuels.

### Réinitialiser sans recharger les poids

`resetConversation(history:)` restaure les messages structurés (`user`, `assistant`, `system`)
en conservant le modèle. L’acteur réserve cette opération, annule une éventuelle génération et
attend son nettoyage avant de transmettre la commande au worker. Une nouvelle génération est
refusée pendant la réinitialisation. Les instructions système sont regroupées dans le message
système unique attendu par Ministral ; les autres messages conservent leur rôle et leur contenu.

`load(progress:)` expose les phases `downloading`, `loading` et `ready`. `load()` reste disponible
et idempotent sur un moteur déjà chargé. Ces phases ne concernent que le modèle, pas les requêtes Web.

## Tests

La cible `NoctisTests` dépend de `Noctis` et de `NoctisCLI`. Les tests du moteur utilisent `@testable import Noctis` et les tests de la console importent aussi `NoctisCLI`. La suite utilise exclusivement **Swift Testing** pour les tests et les assertions, sans dépendance de test supplémentaire et sans XCTest.

Exécuter toute la suite :

```sh
swift test
```

Pour utiliser uniquement les révisions du fichier de résolution existant :

```sh
swift test --disable-automatic-resolution
```

Exécuter une suite ciblée :

```sh
swift test --filter NoctisApplicationTests
swift test --filter MLXModelServiceTests
```

### Isolation du modèle et de la console

- `MockAIModelService` respecte le protocole de production et fournit des réponses ou erreurs prédéfinies.
- Ses appels sont enregistrés dans un `Mutex` de la bibliothèque standard `Synchronization`. Il est `Sendable` sans `@unchecked Sendable`.
- Le mock ne crée aucune tâche de fond. Les fragments sont placés dans un flux fini et déterministe ; aucun délai ni attente arbitraire n’est utilisé.
- Les scénarios de `NoctisApplication` utilisent les [processus isolés de Swift Testing](https://docs.swift.org/latest/documentation/testing/exit-testing/). Chaque processus reçoit une entrée standard en mémoire ; les sorties nécessaires sont capturées par Swift Testing. Le processus principal des tests conserve son entrée standard.
- La suite console a une limite d’une minute par test pour signaler une régression qui bloquerait la boucle de lecture.
- `MLXModelServiceTests` vérifie le refus de générer avant tout chargement. `ModelConcurrencyTests` injecte une fabrique de sessions simulées pour tester le véritable service sans créer de session MLX réelle.

Les tests de réinitialisation vérifient l’historique structuré, l’absence de rechargement, les
échecs et l’attente du nettoyage. Les tests de cache créent une installation temporaire et un
transport sans réseau : deux clients successifs la réutilisent sans aucune requête, tandis
qu’un cache incomplet déclenche le parcours de téléchargement.

**Aucun test unitaire ne charge ni ne télécharge Ministral.** La première compilation des tests peut néanmoins récupérer et compiler les packages Swift déclarés par le projet, y compris les dépendances MLX : isolation du modèle à l’exécution ne signifie pas suppression des dépendances de compilation.

### Scénarios couverts

| Suite | Scénarios |
| --- | --- |
| `NoctisApplicationTests` | Chargement simulé avant le premier prompt ; transmission du texte ; ordre des fragments et affichage Unicode |
| `NoctisApplicationTests` | Appels successifs sans rechargement du moteur ; ordre des réponses |
| `NoctisApplicationTests` | Messages vides, espaces et tabulations ; nettoyage des prompts |
| `NoctisApplicationTests` | Commande `exit` avec casse et espaces ; fin de l’entrée standard |
| `NoctisApplicationTests` | Erreur de chargement : affichage et absence de génération |
| `NoctisApplicationTests` | Erreur avant la création du flux : affichage et reprise au prompt suivant |
| `NoctisApplicationTests` | Erreur du flux avant tout fragment ou après une réponse partielle : texte conservé et reprise |
| `NoctisApplicationTests` | Flux terminé sans fragment ou composé de fragments vides |
| `MLXModelServiceTests` | Erreur `modelNotLoaded` avec prompt normal, vide ou composé d’espaces ; description localisée |
| `ModelConcurrencyTests` | Chargements et générations concurrents, erreurs, annulation, nettoyage et reprise avec des sessions simulées |
| `HTTPWebPageServiceTests` | Refus des URL utilisant un schéma non pris en charge |

Le test d’intégration `SearXNGServiceTests` est désactivé par défaut. Avec Docker et SearXNG démarrés, il peut être lancé explicitement avec `RUN_SEARXNG_TESTS=1 swift test --filter SearXNGServiceTests` ; il effectue une véritable recherche réseau.

### Limites de cette base de tests

- Le téléchargement du modèle, son chargement effectif, le tokenizer, Metal et la qualité des réponses nécessitent des validations d’intégration distinctes. Ils ne sont pas exercés par les tests unitaires.
- Les tests vérifient la réaction de l’application aux erreurs simulées ; ils ne prouvent pas le comportement réseau du chargeur MLX.
- Les flux simulés sont finis et préremplis. Les tests vérifient leur consommation, leur ordre et leurs erreurs, sans mesurer la latence réelle ni la production concurrente de tokens par MLX.
- Les tests de concurrence utilisent des sessions simulées ; ils ne valident pas l’exécution GPU réelle. Les échanges de la CLI restent séquentiels.
- Il n’y a pas de test `ChatService` puisque ce type n’existe pas. La création ultérieure de ce service, de la mémoire ou de l’API Vapor devra s’accompagner de ses propres contrats et tests.

## Diagnostic des problèmes courants

| Symptôme | Vérification |
| --- | --- |
| Le manifeste réclame une autre version de Swift | Vérifier `swift --version` et le compilateur sélectionné dans Xcode ou le gestionnaire de toolchains |
| `cannot execute tool 'metal' due to missing Metal Toolchain` | Vérifier l’installation du composant Metal dans Xcode et sa sélection par le système de build |
| Metal est installé mais SwiftPM continue à utiliser un autre lanceur | Contrôler la sélection des toolchains Swift et Metal de la commande ; ne pas modifier les versions du package pour masquer ce problème d’environnement |
| La résolution des packages échoue | Vérifier l’accès réseau et la cohérence entre `Package.swift` et `Package.resolved` |
| Le lancement réel échoue pendant le chargement | Lire l’erreur affichée, vérifier l’accès au modèle et les ressources du Mac ; ne pas utiliser un lancement réel pour vérifier les tests unitaires |

## Évolutions à construire

La base actuelle peut accueillir ensuite un service de conversation dédié, une mémoire persistante et une API Vapor. Ces évolutions ne sont pas présentes dans cette version. Les tests de caractérisation de la console servent de référence pour préserver les comportements existants lors de leur ajout.

## Recherche Web locale avec SearXNG

Prérequis : Docker avec son moteur démarré (par exemple Docker Desktop sur macOS), Docker Compose et OpenSSL. Le service utilise l’image officielle `searxng/searxng` et conserve les paramètres par défaut, avec les formats HTML et JSON activés.

Depuis la racine du dépôt, créer la configuration locale sans écraser un `.env` existant :

```sh
cp -n .env.example .env
chmod 600 .env
openssl rand -hex 32
```

Remplacer `replace_with_random_secret` dans `.env` par la clé générée. Conserver une clé existante. `SEARXNG_PORT` vaut `8888` par défaut et peut être modifié dans ce même fichier. `.env` et ses variantes sont ignorés par Git ; seul `.env.example`, sans secret, est versionnable.

Compose lit `SEARXNG_SECRET_KEY` dans `.env` et la transmet sous le nom **`SEARXNG_SECRET`**, variable reconnue par le [chargeur officiel de SearXNG](https://docs.searxng.org/admin/settings/settings_server.html). `SEARXNG_SECRET_KEY` n’est pas une variable native de SearXNG. Aucun secret n’est inscrit dans `settings.yml`, et Compose refuse une clé absente ou vide. Le fichier `.env` concerne Docker ; il n’est pas lu par l’application Swift.

Valider puis démarrer :

```sh
docker compose config --quiet
docker compose up -d
docker compose ps
```

L’option `--quiet` valide la configuration sans afficher le secret interpolé. L’instance est accessible uniquement sur `http://127.0.0.1:8888` par défaut. La configuration persistante est montée depuis `infrastructure/searxng` ; le limiteur et le mode instance publique sont désactivés pour cet usage local privé, sans service Valkey supplémentaire.

Tester une véritable recherche JSON (adapter le port si nécessaire) :

```sh
curl -fsS -G "http://127.0.0.1:8888/search" \
  --data-urlencode "q=Swift programming language" \
  --data-urlencode "format=json"
```

La réponse doit contenir un tableau `results` avec des titres, URL et extraits exploitables. SearXNG interroge des moteurs externes : un accès Internet reste nécessaire, et certains moteurs peuvent être temporairement indisponibles.

Pour arrêter le service de ce projet :

```sh
docker compose down
```

Dans ce mode, Docker doit fonctionner pour permettre les recherches Web via l’outil `web_search`. L’inférence du modèle reste locale. Le client Swift utilise `http://127.0.0.1:8888` par défaut ; un changement de port Docker nécessite aussi d’adapter l’URL injectée dans `SearXNGService`.

## SearXNG embarqué sur macOS, sans Docker

`EmbeddedSearXNGService` implémente le même protocole `WebSearchService` et réutilise le
transport URLSession borné existant (2 Mio, délais HTTP, aucune redirection, ni proxy,
cookie ou authentification partagée). Le code est exclu sur iOS.

- Aucun processus Python avant la première recherche valide.
- Un processus, un serveur WSGI Werkzeug sans reloader, une recherche à la fois.
  Une demande concurrente reçoit `EmbeddedSearXNGError.busy` ; l’interface peut la différer.
  SearXNG conserve ses propres threads pour les moteurs : ce n’est pas une limite globale de CPU.
- Port éphémère attribué lors du bind sur `127.0.0.1`, indépendant du port Docker 8888.
  Le parent attend un fichier de disponibilité privé puis une réponse de santé authentifiée.
- Secret SearXNG et jeton HTTP aléatoires renouvelés à chaque lancement. Seuls les GET
  `/search` et `/healthz` avec le jeton sont acceptés ; les requêtes avec `Origin` sont refusées.
  Les en-têtes de proxy transmis sont supprimés. Un autre utilisateur/processus ayant les
  mêmes droits système reste hors du périmètre d’isolation de ce jeton.
- Arrêt après **120 s d’inactivité**, mesurées après la fin de la requête ; jamais pendant
  une recherche. Démarrage limité à **45 s**. Ces deux durées sont configurables à l’initialisation.
- Annulation, erreur HTTP ou crash : abandon du worker, puis redémarrage à la demande suivante.
  Pas de relance automatique d’une requête, ni de bascule silencieuse vers Docker après une erreur.
- `shutdown()` annule la recherche active, ferme le canal de vie et arrête le processus
  (SIGTERM, puis SIGKILL après 500 ms si nécessaire). Python s’arrête aussi à la fermeture
  du canal parent, y compris si l’application plante.

Les paramètres et caches sont créés dans un répertoire temporaire privé, supprimé à l’arrêt.
Un crash brutal du parent peut laisser ce répertoire jusqu’au nettoyage des fichiers temporaires
par le système. Les sorties Python sont écartées pour ne pas conserver requêtes et secrets dans
des logs ; les erreurs exposent le type d’échec et le code de sortie, sans traceback Python.
Le serveur local Werkzeug convient à cette intégration privée, pas à une instance publique.

### Runtime de développement

Pour le CLI macOS, installer le runtime une seule fois depuis le dépôt :

```sh
python3 infrastructure/searxng/setup_runtime.py
swift run
```

Le script nécessite Python 3.10+ et Git, télécharge la révision SearXNG épinglée et installe
ses dépendances dans `~/Library/Application Support/Noctis/SearXNG/venv`, sans installation
Python globale. Il refuse d’écraser une installation existante. Le CLI détecte ce runtime
après la variable explicite et le runtime embarqué, et annonce le mode utilisé au démarrage.
Cette installation locale concerne le CLI ; elle ne remplace pas le packaging signé de Fullmoon.
Les erreurs spécifiques au runtime sont conservées par le dispatcher pour faciliter le diagnostic.

Préparer un Python **3.10 ou plus récent**, les dépendances de la révision SearXNG choisie,
et le package `searx` avec ses données, traductions, templates et fichiers statiques.
macOS ne fournit pas un runtime SearXNG prêt à l’emploi. L’application ne télécharge ni
n’installe Python ou des dépendances pendant son utilisation.

Exemple depuis une copie des sources SearXNG, en dehors du dépôt Noctis :

```sh
python3 -m venv /chemin/absolu/searxng-venv
/chemin/absolu/searxng-venv/bin/python -m pip install setuptools wheel
/chemin/absolu/searxng-venv/bin/python -m pip install -r /chemin/sources/searxng/requirements.txt
/chemin/absolu/searxng-venv/bin/python -m pip install --no-build-isolation --no-deps /chemin/sources/searxng
NOCTIS_SEARXNG_PYTHON=/chemin/absolu/searxng-venv/bin/python swift run NoctisCLI
```

Le chemin doit être absolu. La variable est lue uniquement par le CLI ; `.env` reste réservé
à Docker. Sans variable, sans runtime dans le bundle et sans installation locale du CLI,
le service historique reste sélectionné ; le CLI l’indique et affiche la commande d’installation.
La commande `exit` du CLI appelle explicitement `shutdown()`.

### Application SwiftUI et packaging

Le dépôt contient le package et le CLI ; l’interface SwiftUI Fullmoon est un dépôt distinct.
`MLXModelService()` détecte automatiquement le runtime à cet emplacement dans le bundle principal :

```text
Noctis.app/Contents/Resources/SearXNG/python/bin/python3
```

Pour un arrêt explicite dans l’application, conserver le service et l’injecter :

```swift
let search = try EmbeddedSearXNGService(pythonExecutable: pythonURL)
let model = MLXModelService(webSearchService: search)
// Dans le chemin de terminaison de l’application, avant de confirmer la fermeture :
await search.shutdown()
```

Sur macOS, utiliser le mécanisme de terminaison différée d’AppKit si l’arrêt doit être attendu.
Une disparition de vue SwiftUI ne signifie pas forcément la fermeture de l’application.
Le canal de vie couvre aussi la fermeture sans cet appel explicite.

Pour distribuer, fournir un **Python autonome et relocalisable** pour chaque architecture ciblée,
avec SearXNG et ses dépendances déjà installés. Un venv Homebrew ne constitue pas ce runtime :
il référence souvent l’installation de développement. Le dépôt ne contient aucun binaire Python.
Le script de staging refuse les venv et les liens symboliques sortant du runtime, copie le runtime,
puis vérifie les imports et les préfixes Python après déplacement :

```sh
python3 infrastructure/searxng/package_runtime.py /chemin/python-autonome /chemin/Noctis.app
```

L’application de destination doit déjà exister et le dossier de runtime doit être absent.
Exécuter ce staging **avant la signature finale**. Il ne construit pas Python, ne signe pas
l’application et ne garantit pas à lui seul la portabilité de toutes les bibliothèques natives.
Épingler Python, la révision SearXNG et les dépendances, conserver les notices et les sources
correspondantes de SearXNG (AGPL-3.0-or-later), puis valider sur un Mac sans environnement de développement.

Pour une application sandboxée, le parent doit avoir `com.apple.security.network.client`
et `com.apple.security.network.server`. Le Python enfant doit être signé pour hériter du sandbox
avec exactement ces deux clés App Sandbox :

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.inherit</key><true/>
```

Signer les exécutables, frameworks, dylibs et extensions Python avec l’identité de distribution
appropriée, de l’intérieur vers l’extérieur, puis l’application avec Hardened Runtime ; vérifier
la signature et la notarisation. Ne pas ajouter systématiquement d’exemption à la validation
des bibliothèques ni d’autorisation réseau globale ATS. Vérifier les connexions HTTP locales
avec la politique ATS du bundle cible.
Fullmoon intègre une phase de copie et signature du runtime autonome ; voir son README
pour la préparation. Son sandbox conserve le droit client et ajoute le droit serveur.
Son archive et la validation App Store restent à effectuer dans ce projet séparé.

Le script `setup_runtime.py --standalone --destination /chemin/nouveau-runtime` prépare
Python 3.13.13 relocalisable pour l’architecture du Mac via `uv`, puis installe la même
révision SearXNG que le runtime CLI. Aucun téléchargement n’est effectué par l’app.
`package_runtime.py --sign IDENTITÉ --entitlements /chemin/helper.entitlements` signe
les bibliothèques et l’interpréteur après la vérification des imports dans le bundle déplacé.

### Hôte iOS

Fullmoon fournit `IOSWebSearchService`, conforme à `WebSearchService`, et l’injecte dans
`MLXModelService(webSearchService:)` uniquement sur iOS. Python est intégré au processus
de l’app via son framework iOS ; `EmbeddedSearXNGService` reste réservé à macOS.
`infrastructure/searxng/setup_ios_runtime.py` prépare les dépendances natives arm64 pour
iPhone et simulateur sans modifier les fichiers du runtime Mac. Voir le README Fullmoon
pour les commandes de préparation et le fonctionnement de l’annulation.

Références : [installation SearXNG](https://docs.searxng.org/admin/installation-searxng.html),
[paramètres serveur](https://docs.searxng.org/admin/settings/settings_server.html),
[héritage du sandbox Apple](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html).

### Validation et limites de performances

`EmbeddedSearXNGServiceTests` utilise Python standard et une application WSGI locale factice,
sans moteur externe ni modèle MLX : validation paresseuse, réutilisation, authentification,
rejet des origines et routes non autorisées, arrêt sur inactivité, annulations, timeout,
sortie du parent, concurrence, crash et reprise. Les tests existants du transport restent applicables.
Le test réseau réel est volontairement activé par un chemin de runtime explicite :

```sh
swift test
NOCTIS_TEST_SEARXNG_PYTHON=/chemin/absolu/searxng-venv/bin/python swift test --filter realRuntimeSmoke
```

Validation du 5 novembre 2026 : SearXNG `cccbc9e158b0ac3bb2158e9841a647a5bec57b57`,
Python 3.15 et Swift 6.4.1 sur Apple Silicon. La suite ciblée finale passe avec **17 tests**
dans trois suites, dont le transport existant et le runtime réel. Les deux essais réseau
ont mesuré environ **2,47 s puis 37,48 s à froid**, et **0,90 s puis 0,76 s à chaud**,
avec 41 résultats. Ces valeurs incluent l’initialisation et les moteurs externes ; elles
varient fortement selon le réseau et ne sont pas un benchmark. Aucune mesure de RAM, de batterie ou d’impact pendant une inférence
MLX n’a été effectuée. Le démarrage et les recherches consomment des ressources ; aucun cache
de résultats supplémentaire n’est ajouté. Les recherches nécessitent Internet et peuvent
renvoyer zéro résultat si les moteurs sont bloqués ou indisponibles.

Après correction de la découverte du runtime CLI, le build complet réussit avec les artefacts
locaux disponibles. La suite complète passe ; les tests réseau restent activés explicitement.
Le runtime installé par le script a retourné 41 résultats via le service URLSession réel
(environ 2,26 s à froid et 1,14 s à chaud lors de cet essai). La signature du bundle Fullmoon
et le fonctionnement de bout en bout avec une génération MLX restent à valider.

## SwiftLint

Exécuter le contrôle de style depuis la racine du package :

```sh
./scripts/lint.sh
```

Le script utilise SwiftLint **0.65.1** sur macOS. Au premier lancement, il télécharge
la version portable dans un cache temporaire et vérifie son SHA-256. Pour utiliser
une installation locale de la même version :

```sh
SWIFTLINT_BIN=/chemin/vers/swiftlint ./scripts/lint.sh
```

La configuration `.swiftlint.yml` couvre `Sources`, `Tests` et `Package.swift`, en
excluant les dépendances et les fichiers de build. La baseline conserve les écarts
existants ; toute nouvelle violation échoue en mode strict. Ne pas régénérer la
baseline pour masquer une régression. La même commande peut être utilisée dans la CI.

## Contribuer

Les règles de contribution et les commandes de validation sont décrites dans
[CONTRIBUTING.md](CONTRIBUTING.md).
