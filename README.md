<!-- Created by Sébastien DAGUIN -->

# Noctis 🌙

Noctis est un assistant IA personnel en ligne de commande, développé en Swift pour macOS. Il utilise **Ministral 3 14B Instruct**, au format MLX quantifié sur 4 bits, pour générer ses réponses localement et les afficher progressivement dans le terminal.

Le projet comprend une conversation en streaming et un outil `web_search` connecté à SearXNG. La mémoire persistante et une API Vapor ne sont pas encore implémentées.

Le package expose la bibliothèque `Noctis`, importable dans une application, et l’exécutable `NoctisCLI` pour le terminal.

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

Docker doit fonctionner pour permettre les recherches Web via l’outil `web_search` configuré dans la session MLX. L’inférence du modèle reste locale. Le client Swift utilise `http://127.0.0.1:8888` par défaut ; un changement de port Docker nécessite aussi d’adapter l’URL injectée dans `SearXNGService`.
