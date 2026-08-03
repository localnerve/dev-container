#!/usr/bin/env bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

docker run --rm \
  -v "$ROOT_DIR":/data \
  derlin/docker-compose-viz-mermaid \
  /data/docker-compose.yml -f markdown > "$ROOT_DIR/docs/architecture.md"

# Output a physical image asset (like a PNG or SVG)
docker run --rm \
  -v "$ROOT_DIR":/data \
  derlin/docker-compose-viz-mermaid \
  /data/docker-compose.yml -f svg -o "/data/docs/architecture.svg"