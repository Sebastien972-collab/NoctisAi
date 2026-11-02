<!-- Created by Sébastien DAGUIN -->

# Noctis 🌙

Noctis est un assistant IA personnel en ligne de commande, développé en Swift pour macOS. Il utilise **Ministral 3 14B Instruct**, au format MLX quantifié sur 4 bits, pour générer ses réponses localement et les afficher progressivement dans le terminal.

Le projet constitue actuellement une base de conversation : chargement du moteur, instructions système, boucle de saisie et restitution des fragments de réponse. La mémoire persistante, les outils et une API Vapor ne sont pas encore implémentés.

## Fonctionnalités présentes

- Chargement d’un modèle depuis son identifiant Hugging Face avec MLX Swift LM.
- Initialisation d’une session `ChatSession` avec l’identité et les instructions de Noctis.
- Réutilisation de cette session pendant les échanges du processus courant.
- Lecture de prompts dans le terminal et affichage des fragments au fil de leur réception.
- Suppression des espaces autour des prompts et omission des messages vides.
- Arrêt avec `exit`, quelle que soit la casse, ou à la fermeture de l’entrée standard.
- Affichage des erreurs de chargement, de génération et de lecture du flux.

L’inférence est locale. Le chargement initial peut toutefois télécharger les fichiers du modèle depuis Hugging Face. Le code actuel ne configure pas de mode hors ligne strict ; la disponibilité du cache et les accès réseau au chargement dépendent du chargeur des bibliothèques utilisées.

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
swift run Noctis
```

`swift run Noctis` lance réellement l’assistant : son point d’entrée instancie `MLXModelService`, puis appelle `NoctisApplication.run()`. Cette commande peut donc provoquer le téléchargement et le chargement du modèle. Elle n’est pas utilisée par les tests unitaires.

Une fois le message `Tout est prêt !` affiché, saisir une question après `Vous >`. Les réponses sont affichées après `Noctis 🌙 >`. Saisir `exit` pour terminer.

Pour une compilation optimisée :

```sh
swift build -c release
swift run -c release Noctis
```

Aucun argument de ligne de commande ni fichier de configuration utilisateur n’est actuellement interprété par le programme.

## Configuration

Les valeurs actuelles sont définies dans [NoctisConfiguration.swift](Sources/Noctis/Core/Configuration/NoctisConfiguration.swift) :

| Propriété | Valeur | Rôle |
| --- | --- | --- |
| `modelID` | `mlx-community/Ministral-3-14B-Instruct-2512-4bit` | Modèle utilisé par le chargeur MLX |
| `assistantName` | `Noctis` | Nom affiché au démarrage |
| `exitCommand` | `exit` | Commande de sortie de la conversation |

Le prompt système se trouve dans [NoctisIdentity.swift](Sources/Noctis/NoctisIdentity.swift). Il décrit l’identité, le ton, les capacités actuelles et les règles de comportement de l’assistant. Il est transmis à `ChatSession` lors du chargement du modèle.

Modifier ces constantes ou les instructions nécessite une recompilation. Aucun choix dynamique du modèle ou du prompt système n’est prévu dans l’interface actuelle.

## Organisation du code

```text
Sources/
├── Noctis/
│   ├── Noctis.swift
│   ├── NoctisIdentity.swift
│   └── Core/
│       ├── AI/
│       │   ├── AIModelService.swift
│       │   └── MLXModelService.swift
│       ├── Configuration/
│       │   └── NoctisConfiguration.swift
│       └── Enum/
│           └── MLXModelServiceError.swift
└── NoctisCLI/
    ├── Domain/
    │   └── NoctisApplication.swift
    └── Interface/
        └── ConsoleInterface.swift
Tests/
└── NoctisTests/
    ├── MLXModelServiceTests.swift
    ├── MockAIModelService.swift
    └── NoctisApplicationTests.swift
```

| Élément | Responsabilité réelle |
| --- | --- |
| `Noctis` | Point d’entrée asynchrone ; assemble l’application avec le moteur MLX |
| `NoctisApplication` | Charge le moteur injecté, lit et filtre les entrées, consomme les flux et affiche les erreurs |
| `AIModelService` | Contrat d’inférence injectable : `load()` et `generate(prompt:)` |
| `MLXModelService` | Charge le modèle, conserve une `ChatSession` et expose son flux de réponse |
| `ConsoleInterface` | Regroupe des méthodes de console ; cette structure n’est pas encore utilisée par `NoctisApplication` |
| `NoctisConfiguration` | Constantes de configuration compilées avec l’application |
| `NoctisIdentity` | Instructions système transmises à la session |

Les dossiers `Noctis` et `NoctisCLI` sont compilés ensemble dans **une seule cible exécutable `Noctis`**, grâce aux propriétés `path` et `sources` de `Package.swift`. `NoctisCLI` n’est pas un module Swift distinct.

**Il n’existe pas de `ChatService` dans cette révision.** La gestion des échanges est portée par `NoctisApplication`. Les tests couvrent ce code existant ; aucun service ni découpage supplémentaire n’a été ajouté pour les besoins des tests.

## Contrat du moteur et cycle d’une conversation

Le protocole `AIModelService` expose :

```swift
func load() async throws
func generate(prompt: String) throws -> AsyncThrowingStream<String, Error>
```

1. `NoctisApplication` reçoit son moteur par injection de constructeur.
2. `run()` appelle `load()` avant d’accepter les échanges.
3. `MLXModelService.load()` charge le modèle et crée une `ChatSession` avec le prompt système.
4. Chaque message non vide, après suppression des espaces périphériques, est transmis à `generate(prompt:)`.
5. L’application lit le flux avec `for try await` et imprime chaque fragment immédiatement.
6. La même instance du moteur est utilisée pour les messages suivants ; la boucle ne rappelle pas `load()` à chaque échange.

Deux moments d’échec sont possibles lors de la génération :

- **Avant de retourner un flux** : `generate(prompt:)` peut lever une erreur synchrone. L’implémentation MLX lève `MLXModelServiceError.modelNotLoaded` si aucune session n’a été chargée.
- **Pendant la consommation du flux** : l’itération asynchrone peut lever une erreur après zéro ou plusieurs fragments. Les fragments déjà affichés restent visibles.

L’application affiche ces erreurs puis accepte le message suivant. Un échec initial de `load()` interrompt au contraire le démarrage de la conversation. `run()` affiche l’erreur et termine normalement : il ne la propage pas à son appelant.

## Dépendances

Le manifeste déclare les packages suivants :

| Package | Produits directement utilisés par la cible |
| --- | --- |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | `MLXLMCommon`, `MLXVLM`, `MLXHuggingFace` |
| [swift-huggingface](https://github.com/huggingface/swift-huggingface) | `HuggingFace` |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | `Tokenizers` |

`Package.resolved` enregistre les révisions exactes, y compris celle du package `mlx-swift-lm` déclaré sur la branche `main`. Conserver ce fichier permet de partager les mêmes révisions entre développeurs.

La présence de `MLXVLM` dans les dépendances ne constitue pas une interface de saisie d’images : la CLI actuelle transmet uniquement des prompts textuels.

## Tests

La cible `NoctisTests` dépend de `Noctis` et utilise `@testable import Noctis`. La suite utilise exclusivement **Swift Testing** pour les tests et les assertions, sans dépendance de test supplémentaire et sans XCTest.

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
- Le seul test qui instancie `MLXModelService` vérifie son refus de générer **avant tout chargement**. Il n’appelle jamais son `load()`.

**Aucun test unitaire ne charge ni ne télécharge Ministral.** La première compilation des tests peut néanmoins récupérer et compiler les packages Swift déclarés par le projet, y compris les dépendances MLX : isolation du modèle à l’exécution ne signifie pas suppression des dépendances de compilation.

### Scénarios couverts

| Suite | Scénarios |
| --- | --- |
| `NoctisApplicationTests` | Chargement simulé avant le premier prompt ; transmission du texte ; ordre des fragments et affichage Unicode |
| `NoctisApplicationTests` | Appels successifs sans rechargement du moteur ; ordre des réponses |
| `NoctisApplicationTests` | Messages vides, espaces et tabulations ; nettoyage des prompts |
| `NoctisApplicationTests` | Commande `exit` avec casse et espaces ; fin de l’entrée standard |
| `NoctisApplicationTests` | Erreur de chargement : affichage et absence de génération |
| `NoctisApplicationTests` | Erreur synchrone de génération : affichage et reprise au prompt suivant |
| `NoctisApplicationTests` | Erreur du flux avant tout fragment ou après une réponse partielle : texte conservé et reprise |
| `NoctisApplicationTests` | Flux terminé sans fragment ou composé de fragments vides |
| `MLXModelServiceTests` | Erreur `modelNotLoaded` avec prompt normal, vide ou composé d’espaces ; description localisée |

### Limites de cette base de tests

- Le téléchargement du modèle, son chargement effectif, le tokenizer, Metal et la qualité des réponses nécessitent des validations d’intégration distinctes. Ils ne sont pas exercés par les tests unitaires.
- Les tests vérifient la réaction de l’application aux erreurs simulées ; ils ne prouvent pas le comportement réseau du chargeur MLX.
- Les flux simulés sont finis et préremplis. Les tests vérifient leur consommation, leur ordre et leurs erreurs, sans mesurer la latence réelle ni la production concurrente de tokens par MLX.
- Aucune garantie de sécurité des appels concurrents n’est ajoutée au moteur de production. Les échanges réels de la CLI sont séquentiels.
- Il n’y a pas de test `ChatService` puisque ce type n’existe pas. La création ultérieure de ce service, de la mémoire, des outils ou de l’API Vapor devra s’accompagner de ses propres contrats et tests.

## Diagnostic des problèmes courants

| Symptôme | Vérification |
| --- | --- |
| Le manifeste réclame une autre version de Swift | Vérifier `swift --version` et le compilateur sélectionné dans Xcode ou le gestionnaire de toolchains |
| `cannot execute tool 'metal' due to missing Metal Toolchain` | Vérifier l’installation du composant Metal dans Xcode et sa sélection par le système de build |
| Metal est installé mais SwiftPM continue à utiliser un autre lanceur | Contrôler la sélection des toolchains Swift et Metal de la commande ; ne pas modifier les versions du package pour masquer ce problème d’environnement |
| La résolution des packages échoue | Vérifier l’accès réseau et la cohérence entre `Package.swift` et `Package.resolved` |
| Le lancement réel échoue pendant le chargement | Lire l’erreur affichée, vérifier l’accès au modèle et les ressources du Mac ; ne pas utiliser un lancement réel pour vérifier les tests unitaires |

## Évolutions à construire

La base actuelle peut accueillir ensuite un service de conversation dédié, une mémoire persistante, des outils et une API Vapor. Ces évolutions ne sont pas présentes dans cette version. Les tests de caractérisation de la console servent de référence pour préserver les comportements existants lors de leur ajout.
