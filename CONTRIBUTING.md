<!-- Created by Sébastien DAGUIN -->

# Contribuer à NoctisAI

Merci de proposer des changements ciblés, cohérents avec le code existant.

## Préparer l'environnement

- Utiliser un Mac Apple Silicon pour la chaîne MLX/Metal actuellement validée.
- Installer Xcode et une toolchain Swift 6.4 ou ultérieure, conformément à `Package.swift`.
- Installer le composant Metal de Xcode s'il manque : `xcodebuild -downloadComponent MetalToolchain`.
- Disposer d'un accès réseau pour récupérer les dépendances et SwiftLint au premier lancement.

Les sources de la bibliothèque sont dans `Sources/Noctis`, celles du terminal dans
`Sources/NoctisCLI` et les tests dans `Tests/NoctisTests`.

## Travailler sur une branche

Créer une branche dédiée depuis `main` à jour, par exemple `feat/nom-court`,
`fix/nom-court` ou `docs/nom-court`. Garder chaque contribution centrée sur un seul sujet.

Toute contribution passe par une pull request vers `main`, y compris les corrections
mineures. Les pushes directs, force-pushes et suppressions de `main` sont interdits.
La fusion est réservée à **Sébastien DAGUIN (`Sebastien972-collab`)**.

## Style et périmètre

Respecter l'architecture, les noms et les conventions existants. Privilégier les
modifications simples dans les fichiers présents ; éviter les abstractions inutiles
et les refontes sans rapport avec la demande. Vérifier les usages avant de supprimer du code.

Limiter les commentaires aux décisions ou logiques qui nécessitent une explication.
Préserver les headers existants et les attributions des bibliothèques tierces.
Ne pas signer des fichiers avec le nom d'un outil IA.

Les changements d'architecture, de dépendances, de SDK ou de fichiers de build doivent
faire partie du périmètre annoncé et être expliqués dans la pull request.

## Valider avant la pull request

Depuis la racine du package :

```sh
./scripts/lint.sh
xcodebuild -scheme Noctis-Package -destination 'platform=macOS' \
  -skipMacroValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test
```

Le script utilise SwiftLint 0.65.1, téléchargé dans un cache temporaire et vérifié par
SHA-256. `SWIFTLINT_BIN=/chemin/vers/swiftlint ./scripts/lint.sh` permet d'utiliser une
installation locale de la même version.

La baseline `.swiftlint-baseline.json` conserve les violations présentes lors de
l'intégration du lint. Les nouvelles violations sont bloquantes. Ne pas régénérer
la baseline pour contourner une erreur ; corriger le code concerné.

Ajouter des tests ciblés lorsqu'un changement de logique ou une régression le justifie.
Les tests courants n'ont pas besoin de télécharger les poids du modèle. Les tests
SearXNG réels sont optionnels et nécessitent un runtime explicitement configuré ;
voir [README.md](README.md). Ne pas les présenter comme exécutés s'ils ne l'ont pas été.

## Décrire la contribution

La pull request doit expliquer le problème, le comportement obtenu et les vérifications
réalisées. Signaler les limites, tests non exécutés et éventuelles évolutions de l'API
publique. Éviter les changements de formatage ou de dépendances étrangers au sujet.

Ne pas versionner de secrets, fichiers `.env`, poids de modèles, caches, runtimes Python
ou artefacts de build. Respecter les licences et notices des dépendances utilisées.
