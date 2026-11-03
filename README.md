<!-- Created by Sébastien DAGUIN -->

# Noctis 🌙

Assistant IA personnel développé en Swift 6.4 pour macOS, avec MLX Swift LM et Ministral 3 14B Instruct en local.

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

Docker doit fonctionner pour permettre les recherches Web. Cette infrastructure est indépendante de l’inférence locale : le chat Swift n’appelle pas encore SearXNG, et aucun Tool Calling n’est ajouté.

