#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

load_env_file() {
  [[ -f .env ]] || return

  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    value="${value%$'\r'}"
    value="${value#\"}"
    value="${value%\"}"
    export "$key=$value"
  done < <(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' .env)
}

load_env_file

web_image="${WEB_IMAGE:-chatchat_web:act}"
broker_image="${BROKER_IMAGE:-chatchat_broker:act}"
web_port="${PORT:-4000}"
postgres_db="${POSTGRES_DB:-chatchat_dev}"
postgres_user="${POSTGRES_USER:-chatchat}"
postgres_password="${POSTGRES_PASSWORD:-chatchat}"
database_url="ecto://${postgres_user}:${postgres_password}@db:5432/${postgres_db}"
secret_key_base="${SECRET_KEY_BASE:-$(openssl rand -hex 64)}"

for image in "$web_image" "$broker_image"; do
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "Image $image does not exist. Run: act push -W .github/workflows/images.yml" >&2
    exit 1
  fi
done

docker compose up -d db

echo "Waiting for PostgreSQL..."
until docker compose exec -T db sh -c 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null 2>&1; do
  sleep 1
done

echo "Running migrations..."
docker run --rm \
  --network chatchat_default \
  --env "DATABASE_URL=$database_url" \
  --env "SECRET_KEY_BASE=$secret_key_base" \
  "$web_image" eval 'ChatchatBroker.Release.migrate()'

for container in chatchat-broker chatchat-web; do
  if docker container inspect "$container" >/dev/null 2>&1; then
    docker rm --force "$container" >/dev/null
  fi
done

docker run --detach \
  --name chatchat-broker \
  --restart unless-stopped \
  --network chatchat_default \
  --env "DATABASE_URL=$database_url" \
  "$broker_image" >/dev/null

docker run --detach \
  --name chatchat-web \
  --restart unless-stopped \
  --network chatchat_default \
  --publish "$web_port:4000" \
  --env "DATABASE_URL=$database_url" \
  --env "SECRET_KEY_BASE=$secret_key_base" \
  "$web_image" >/dev/null

echo "ChatChat is running at http://localhost:$web_port"
echo "Logs: docker logs -f chatchat-web"
