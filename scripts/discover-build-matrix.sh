#!/usr/bin/env bash
set -euo pipefail

# Discover build matrix from containers/openami/* directories.
# Each image directory must contain:
#   - One or more Dockerfiles under version/distro subdirs (e.g. 1.29/debian-12/Dockerfile)
#   - tags.txt listing tags to build. Format per line:
#       TAG [RELATIVE_CONTEXT]
#     Examples:
#       1.29.1-debian-12-r0 1.29/debian-12
#       1.29.1-debian-12-r0       # (no context given; infer "1.29/debian-12")
#
# Emits a GitHub Actions matrix with entries:
#   { name, tag, context, dockerfile }
#
# Outputs via GITHUB_OUTPUT:
#   matrix: JSON string like {"include":[{...}, ...]}
#   missing_dockerfile: JSON array of image names entirely missing any Dockerfile
#   missing_tags: JSON array of image names missing tags.txt or with no valid tags
#   missing_context: JSON array of "image:tag" entries where a Dockerfile could not be resolved
#
# Environment:
#   OPENAMI_DIR (default: containers/openami)
#   STRICT_MISSING (default: "true") -> if "true" and any missing_* present, exit 1

OPENAMI_DIR="${OPENAMI_DIR:-containers/openami}"
STRICT_MISSING="${STRICT_MISSING:-true}"

if [[ ! -d "${OPENAMI_DIR}" ]]; then
  echo "ERROR: OPENAMI_DIR not found: ${OPENAMI_DIR}" >&2
  exit 1
fi

# jq is required on GH runners
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

# Helper: trim whitespace
trim() {
  local s="$*"
  # shellcheck disable=SC2001
  s="$(echo -e "$s" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  printf "%s" "$s"
}

# Helper: infer version/distro context from a tag string.
# Heuristics:
#  - version: take first two numeric segments (e.g., 1.29 from 1.29.1-debian-12-r0)
#  - distro: prefer one of known tokens if present in tag
infer_context_from_tag() {
  local tag="$1"
  local version=""
  local distro=""

  # version: major.minor at start of tag
  if [[ "$tag" =~ ^([0-9]+)\.([0-9]+) ]]; then
    version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  fi

  # distro candidates
  if   [[ "$tag" == *"-debian-12"* ]]; then
    distro="debian-12"
  elif [[ "$tag" == *"-ubuntu-22.04"* ]]; then
    distro="ubuntu-22.04"
  elif [[ "$tag" =~ -alpine-([0-9]+\.[0-9]+) ]]; then
    distro="alpine-${BASH_REMATCH[1]}"
  elif [[ "$tag" == *"-alpine"* ]]; then
    distro="alpine"
  fi

  # Fallbacks if inference failed
  [[ -z "$version" ]] && version="latest"
  [[ -z "$distro"  ]] && distro="debian-12"

  printf "%s/%s" "$version" "$distro"
}

images=()
while IFS= read -r -d '' d; do
  images+=("$d")
done < <(find "${OPENAMI_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

matrix_include='[]'
missing_dockerfile='[]'
missing_tags='[]'
missing_context='[]'

for dir in "${images[@]}"; do
  name="$(basename "$dir")"
  tfile="${dir}/tags.txt"

  # Does the image directory contain any Dockerfile at all?
  if ! find "$dir" -type f -name Dockerfile -print -quit >/dev/null; then
    # No Dockerfile contexts in this image directory; skip it silently
    continue
  fi

  # tags.txt presence
  if [[ ! -f "${tfile}" ]]; then
    missing_tags="$(jq -c --arg n "$name" '. + [$n]' <<<"$missing_tags")"
    continue
  fi

  # Parse tags file
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="$(trim "$raw")"
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue

    # Split by whitespace into at most 2 tokens: TAG [REL_CONTEXT]
    tag="$(trim "$(printf "%s" "$line" | awk '{print $1}')" )"
    rel="$(trim "$(printf "%s" "$line" | awk 'NF>1{print $2}')" )"

    if [[ -z "$tag" ]]; then
      continue
    fi

    if [[ -z "$rel" ]]; then
      rel="$(infer_context_from_tag "$tag")"
    fi

    context="${dir}/${rel}"
    dfile="${context}/Dockerfile"

    if [[ ! -f "$dfile" ]]; then
      # Record missing for this specific tag
      missing_context="$(jq -c --arg p "${name}:${tag}" '. + [$p]' <<<"$missing_context")"
      continue
    fi

    entry=$(jq -c -n \
      --arg name "$name" \
      --arg tag "$tag" \
      --arg context "$context" \
      --arg dockerfile "$dfile" \
      '{name:$name, tag:$tag, context:$context, dockerfile:$dockerfile}')
    matrix_include="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$matrix_include")"
  done < "$tfile"
done

matrix_json=$(jq -c -n --argjson inc "$matrix_include" '{include:$inc}')

# Write to GITHUB_OUTPUT (if defined), else print
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "matrix=${matrix_json}"
    echo "missing_dockerfile=$(jq -c '.' <<<"$missing_dockerfile")"
    echo "missing_tags=$(jq -c '.' <<<"$missing_tags")"
    echo "missing_context=$(jq -c '.' <<<"$missing_context")"
  } >> "$GITHUB_OUTPUT"
else
  echo "matrix=${matrix_json}"
  echo "missing_dockerfile=$(jq -c '.' <<<"$missing_dockerfile")"
  echo "missing_tags=$(jq -c '.' <<<"$missing_tags")"
  echo "missing_context=$(jq -c '.' <<<"$missing_context")"
fi

# Strict mode: fail if any missing
if [[ "$STRICT_MISSING" == "true" ]]; then
  mt_count=$(jq -r 'length' <<<"$missing_tags")
  mc_count=$(jq -r 'length' <<<"$missing_context")
  if [[ "$mt_count" -gt 0 || "$mc_count" -gt 0 ]]; then
    echo "ERROR: Missing build metadata detected." >&2
    if [[ "$mt_count" -gt 0 ]]; then
      echo " - Missing or empty tags.txt for images: $(jq -r '.|join(", ")' <<<"$missing_tags")" >&2
    fi
    if [[ "$mc_count" -gt 0 ]]; then
      echo " - Missing context/Dockerfile for image:tag: $(jq -r '.|join(", ")' <<<"$missing_context")" >&2
    fi
    exit 1
  fi
fi
