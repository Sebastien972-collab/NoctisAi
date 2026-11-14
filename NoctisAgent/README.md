<!-- Created by Sébastien DAGUIN -->

# NoctisAgent

Package Swift natif pour macOS 15 et iOS 17, sans dépendance externe. Le moteur est injecté via `AgentModel`. `AgentRuntime` conserve la dernière `AgentSession` et effectue les cycles modèle → validation → outils → résultats. Chaque appel `run` démarre une nouvelle session en mémoire.

## Intégration Noctis / MLX

```swift
import Foundation
import Noctis
import NoctisAgent

// Le chemin doit provenir d'une sélection explicitement autorisée par l'utilisateur.
let workspace = try AuthorizedWorkspace(authorizing: selectedDirectoryURL)
let model = MLXModelService(modelID: "mlx-community/Ministral-3-14B-Instruct-2512-4bit")
try await model.load()
let runtime = try await model.makeAgentRuntime(workspace: workspace, limits: AgentLimits())
let session = try await runtime.run(prompt: "Explique l'architecture de ce projet")
```

Un service MLX déjà chargé peut être réutilisé, avec son modèle courant. L'agent partage ses poids et interdit les générations simultanées avec la conversation. Les schémas d'outils et les messages assistant/tool sont transmis nativement à MLX ; aucune extraction d'appel depuis du texte libre. L'agent ne reçoit pas les outils web de la conversation. Ministral 3 14B est le modèle par défaut sur macOS, et Ministral 3 3B reste utilisé sur iOS.

## Conversation native, indépendante du CLI

Le moteur de conversation MLX propose aussi directement les trois outils, sans utiliser le mode de tâches `AgentRuntime` :

```swift
let model = MLXModelService()
try await model.authorizeWorkspace(workspace)
try await model.load()
try await model.withResponse(prompt: "Explique comment ce projet charge son modèle") { stream in
    for try await chunk in stream { print(chunk, terminator: "") }
}
```

Ministral choisit les appels structurés selon la demande. Le même flux conserve le contexte entre les questions.
Le CLI utilise désormais `NoctisCLIAgent` et sa boucle `Agent`, avec `--workspace` au démarrage ou `/workspace /chemin/absolu`
pendant la conversation. `/workspace off` révoque l'accès. Aucune commande de mode code ni application externe.
L'autorisation est une décision de l'hôte, jamais un outil du modèle.

Changer ou révoquer le dossier réinitialise l'historique pour séparer les données locales du Web.
Lorsque le dossier est autorisé, seuls les trois outils locaux sont déclarés et le Web est désactivé.
Sans autorisation, seul le périmètre Web habituel est disponible.
Le dispatch natif est limité à 8 appels et 256 Kio de résultats par réponse utilisateur,
avec au plus 2 048 tokens par génération MLX. Le contexte de conversation s'accumule entre les échanges ;
le budget global du transcript de `AgentRuntime` ci-dessous s'applique uniquement à son API de tâches.

## Périmètre et limites

- `listFiles(path:)` : un dossier, au plus 200 entrées examinées, résultat trié et indicateur `truncated`.
- `readFile(path:)` : fichier régulier UTF-8 sans NUL, au plus 64 Kio.
- `searchCode(path:query:)` : recherche littérale sensible à la casse, lignes numérotées à partir de 1 ; au plus 1 000 entrées, 64 fichiers, profondeur 16, 50 résultats. Extraits de 128 scalaires Unicode. Les fichiers illisibles, volumineux ou binaires sont comptés dans `skippedFiles`.
- `.git`, `.build`, `node_modules` et `.DS_Store` sont ignorés dans les listes et recherches ; une lecture explicite d'un fichier caché autorisé reste possible.
- Par défaut : 8 itérations, 4 appels par tour, contexte JSON limité à 256 Kio et texte modèle à 32 Kio. Chaque résultat d'outil est limité à 96 Kio après encodage JSON. MLX génère au plus 2 048 tokens par tour ; une sortie coupée est signalée comme erreur.
- Les erreurs d'outils sont renvoyées au modèle sous forme de codes stables. Les erreurs du moteur, de protocole, de budget et les annulations arrêtent la session ; la session partielle reste consultable.
- Annulation via `Task.cancel()`. Le moteur rejoint le producteur MLX avant de libérer son verrou ; l'annulation peut attendre le premier événement MLX pendant le prefill.
- `applyPatch`, `runCommand` et `gitDiff` existent uniquement comme signatures dans `AgentWorkspaceActions`. Aucun schéma, routage ou implémentation n'est activé.

## Autorisation et protection des chemins

L'application hôte doit obtenir l'autorisation avant de construire `AuthorizedWorkspace`. Aucune autorisation ne peut venir du modèle. Sur iOS ou dans une app sandboxée, l'hôte doit conserver l'accès security-scoped pendant toute la session.

Les ouvertures sont relatives à des descripteurs POSIX avec `O_NOFOLLOW`, sans vérification par simple préfixe. Le dossier racine est conservé par descripteur. Les chemins absolus d'outils, `..`, NUL, liens symboliques (y compris dans les parents du dossier autorisé), liens physiques multiples et fichiers spéciaux sont refusés. Utiliser un chemin canonique : `/private/tmp`, par exemple, car `/tmp` et `/var` sont des liens système sur macOS.

Les noms et contenus sont étiquetés comme données non fiables. Cette indication aide le modèle ; la frontière de sécurité reste la validation et les ouvertures système. Le package est basé sur Darwin et n'isole pas le processus hôte. Il ne filtre pas les secrets présents dans le dossier autorisé. Les fichiers peuvent changer pendant une lecture : ce n'est pas un snapshot du dépôt.

`NoctisFileSystem`, package voisin, reste inchangé : sa résolution par URL ne garantit pas l'absence de substitution de chemin entre validation et ouverture.

## Tests

Depuis ce dossier : `swift test`. Depuis Noctis : `swift test` pour l'adaptateur et les tests existants. Les tests du package utilisent un modèle simulé et ne téléchargent aucun poids. Ils ne mesurent pas la qualité de Ministral ni l'inférence GPU réelle. Le CLI utilise les outils via la conversation native avec `swift run NoctisCLI --workspace /chemin/absolu`. La sélection graphique reste à raccorder par l'application hôte.


La stabilisation bêta impose huit appels et 256 Kio de résultats cumulés par tâche, même si plusieurs
itérations sont nécessaires. Les runtimes construits par `MLXModelService.makeAgentRuntime` sont liés
à la révision des permissions du service : une révocation ou une remise à zéro les invalide. Le registre
standalone construit directement par l’hôte conserve son autorisation propre. Tous les modèles chargés
par le service utilisent aussi le contrôle de contexte avant chaque génération (6 144 tokens d’entrée
et 2 048 de sortie, ou moins si la fenêtre du modèle l’exige).
