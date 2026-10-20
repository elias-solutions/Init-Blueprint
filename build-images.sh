#!/usr/bin/env bash
# Builds the API images (publish → image build), applies the EF Core migrations
# to the compose Postgres and starts all compose services.
# Existing images are skipped unless --force is given.
# Usage: ./build-images.sh [-f|--force]
set -uo pipefail

# Auto-detect container engine: prefer podman if available, fall back to docker
if command -v podman >/dev/null 2>&1; then
  CONTAINER_ENGINE="podman"
  COMPOSE_ENGINE="podman-compose"
else
  CONTAINER_ENGINE="docker"
  COMPOSE_ENGINE="docker compose"
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECTS_ROOT="$(cd "$ROOT/.." && pwd)"
FORCE=false

for arg in "$@"; do
  case "$arg" in
    -f|--force) FORCE=true ;;
    *)
      echo "ERROR: unknown argument '$arg' (expected -f|--force)"
      exit 1
      ;;
  esac
done

echo "Engine: $CONTAINER_ENGINE (force=$FORCE)"

publish_net_api() {
  local project="$1"
  rm -rf "$PROJECTS_ROOT/NET-Blueprint/publish/$project"
  dotnet publish "$PROJECTS_ROOT/NET-Blueprint/$project/$project.csproj" \
    -c Release -p:UseAppHost=false -o "$PROJECTS_ROOT/NET-Blueprint/publish/$project"
}

package_java_api() {
  (cd "$PROJECTS_ROOT/Java-Blueprint" && ./mvnw -B -q clean package -DskipTests)
}

migrate_net_database() {
  $COMPOSE_ENGINE -f "$ROOT/docker-compose.yml" up -d postgres || return 1

  echo "Waiting for postgres"
  local ready=false
  for _ in {1..30}; do
    if $CONTAINER_ENGINE exec blueprint-postgres pg_isready -U blueprint -d blueprint_net >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 2
  done
  [[ "$ready" == true ]] || { echo "ERROR: postgres not ready"; return 1; }

  dotnet ef database update \
    --project "$PROJECTS_ROOT/NET-Blueprint/NET.Backend.Blueprint.Infrastructure/NET.Backend.Blueprint.Infrastructure.csproj"
}

# project entry: image|dockerfile|context|prebuild (paths relative to PROJECTS_ROOT, prebuild = command + args)
PROJECTS=(
  "blueprint-net-api:latest|NET-Blueprint/NET.Backend.Blueprint.Api/Dockerfile|NET-Blueprint|publish_net_api NET.Backend.Blueprint.Api"
  "blueprint-net-minimal-api:latest|NET-Blueprint/NET.Backend.Blueprint.Minimal.Api/Dockerfile|NET-Blueprint|publish_net_api NET.Backend.Blueprint.Minimal.Api"
  "blueprint-java-api:latest|Java-Blueprint/Dockerfile|Java-Blueprint|package_java_api"
  "blueprint-ai-api:latest|Python-Blueprint/Dockerfile|Python-Blueprint|true"
)

FAILED=()

for proj in "${PROJECTS[@]}"; do
  IFS='|' read -r IMAGE DOCKERFILE CONTEXT PREBUILD <<< "$proj"

  echo ""
  echo "=== $IMAGE ==="

  (
    IMAGE_EXISTS=false
    $CONTAINER_ENGINE image inspect "$IMAGE" >/dev/null 2>&1 && IMAGE_EXISTS=true

    if [[ "$FORCE" == false && "$IMAGE_EXISTS" == true ]]; then
      echo "Image exists -> skip build"
    else
      if [[ "$FORCE" == true ]]; then
        echo "Force rebuild requested"
      else
        echo "Image missing -> build"
      fi

      $PREBUILD || exit 1
      $CONTAINER_ENGINE build -t "$IMAGE" -f "$PROJECTS_ROOT/$DOCKERFILE" "$PROJECTS_ROOT/$CONTEXT" || exit 1
    fi
  ) || { echo "ERROR: failed to process $IMAGE"; FAILED+=("$IMAGE"); }
done

echo ""
echo "=== EF Core migrations (blueprint_net) ==="
migrate_net_database || { echo "ERROR: EF Core migration failed"; FAILED+=("ef-migrations"); }

if (( ${#FAILED[@]} > 0 )); then
  echo ""
  echo "Failed: ${FAILED[*]}"
  exit 1
fi

echo ""
echo "=== Starting services ==="
$COMPOSE_ENGINE -f "$ROOT/docker-compose.yml" up -d
