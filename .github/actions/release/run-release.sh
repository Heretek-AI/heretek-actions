#!/usr/bin/env bash
set -euo pipefail

source "${AGENT_ACTION_PATH}/../agent-envelope.sh"

echo "🚀 Running release: ${{ inputs.release-type }} version=${{ inputs.version }}"

RELEASE_TYPE="${{ inputs.release-type }}"
VERSION="${{ inputs.version }}"
NOTES="${{ inputs.release-notes }}"
GENERATE_NOTES="${{ inputs.generate-notes }}"
PRERELEASE="${{ inputs.prerelease }}"
MAKE_LATEST="${{ inputs.make-latest }}"

owner="${GITHUB_REPOSITORY_OWNER:-}"
repo="${GITHUB_REPOSITORY#*/}"

# Strip leading v if present
TAG="${VERSION#v}"
TAG="v${TAG}"

ASSETS="${{ inputs.assets }}"

release_url=""
published=false
assets_list='[]'

case "$RELEASE_TYPE" in
  docker)
    echo "🐳 Building Docker image..."

    IMAGE_NAME="${{ inputs.docker-image-name }}"
    PLATFORMS="${{ inputs.docker-platforms }}"

    # Convert owner to lowercase for ghcr.io
    IMAGE_NAME_LC=$(echo "${IMAGE_NAME}" | tr '[:upper:]' '[:lower:]')
    GHCR_IMAGE="ghcr.io/${IMAGE_NAME_LC}:${TAG}"

    # Set up Docker Buildx
    docker buildx create --use --name multiarch 2>/dev/null || true
    docker buildx build \
      --file "${{ inputs.dockerfile }}" \
      --platform "${PLATFORMS}" \
      --tag "${GHCR_IMAGE}" \
      --push \
      . 2>&1

    echo "✅ Docker image pushed: ${GHCR_IMAGE}"
    published=true
    release_url="https://github.com/${owner}/${repo}/pkgs/container/${IMAGE_NAME_LC}"
    assets_list=$(cat <<ASSETS
      [{"name": "${IMAGE_NAME_LC}:${TAG}", "url": "${release_url}/versions"}]
ASSETS
    )
    ;;

  flatpak)
    echo "📦 Building Flatpak..."

    MANIFEST="${{ inputs.flatpak-manifest }}"
    BRANCH="${{ inputs.flatpak-branch }}"

    # Install flatpak-builder if needed
    command -v flatpak-builder >/dev/null 2>&1 || {
      apt-get update && apt-get install -y flatpak flatpak-builder 2>/dev/null ||
      dnf install -y flatpak flatpak-builder 2>/dev/null || true
    }

    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true

    flatpak-builder \
      --repo=repo \
      --force-clean \
      --default-branch="${BRANCH}" \
      build-dir \
      "${MANIFEST}" 2>&1

    flatpak build-bundle repo "${repo}-${TAG}.flatpak" \
      "$(grep 'app-id' "${MANIFEST}" | awk '{print $2}' | tr -d '"')" \
      "${BRANCH}" 2>&1

    published=true
    release_url="https://github.com/${owner}/${repo}/releases/tag/${TAG}"
    assets_list=$(cat <<ASSETS
      [{"name": "${repo}-${TAG}.flatpak", "url": "${release_url}"}]
ASSETS
    )
    ;;

  npm)
    echo "📦 Publishing npm package..."

    # Set version
    npm version "${VERSION#v}" --no-git-tag-version 2>&1 || true

    if [ "${{ inputs.npm-dry-run }}" = "true" ]; then
      npm publish --dry-run 2>&1
      published=false
    else
      if [ -n "${NPM_TOKEN:-}" ]; then
        echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN}" > ~/.npmrc
      fi
      npm publish 2>&1
      published=true
    fi

    release_url="https://www.npmjs.com/package/${repo}"
    assets_list='[]'
    ;;

  github-release)
    echo "🏷️ Creating GitHub release..."

    # Create release
    if [ "$GENERATE_NOTES" = "true" ] && [ -z "$NOTES" ]; then
      RELEASE_DATA=$(gh release create "${TAG}" \
        --repo "${owner}/${repo}" \
        --title "${TAG}" \
        --generate-notes \
        $([ "$PRERELEASE" = "true" ] && echo "--prerelease") \
        $([ "$MAKE_LATEST" != "true" ] && echo "--latest=false") \
        --json url --jq '.url' 2>&1)
    else
      NOTES="${NOTES:-Release ${TAG}}"
      NOTES_FILE=$(mktemp)
      echo "$NOTES" > "$NOTES_FILE"
      RELEASE_DATA=$(gh release create "${TAG}" \
        --repo "${owner}/${repo}" \
        --title "${TAG}" \
        --notes-file "$NOTES_FILE" \
        $([ "$PRERELEASE" = "true" ] && echo "--prerelease") \
        $([ "$MAKE_LATEST" != "true" ] && echo "--latest=false") \
        --json url --jq '.url' 2>&1)
      rm -f "$NOTES_FILE"
    fi

    release_url="$RELEASE_DATA"
    published=true

    # Upload assets
    if [ "$ASSETS" != "[]" ]; then
      echo "$ASSETS" | jq -c '.[]' | while IFS= read -r asset; do
        ASSET_PATH=$(echo "$asset" | jq -r '.path')
        ASSET_NAME=$(echo "$asset" | jq -r '.name // .path | split("/")[-1]')
        if [ -f "$ASSET_PATH" ]; then
          gh release upload "${TAG}" "$ASSET_PATH" --repo "${owner}/${repo}" --clobber 2>&1
        fi
      done
    fi
    ;;
esac

# --- Build envelope ---
AGENT_OUTPUTS=$(cat <<OUTPUTS
{
  "release_type": "${RELEASE_TYPE}",
  "version": "${TAG}",
  "published": ${published},
  "release_url": "${release_url:-}"
}
OUTPUTS
)
export AGENT_OUTPUTS
export AGENT_RELEASE=$(cat <<RELEASE
{
  "version": "${TAG}",
  "tag": "${TAG}",
  "published": ${published},
  "assets": ${assets_list},
  "release_url": "${release_url:-}"
}
RELEASE
)

SUMMARY="${RELEASE_TYPE} release ${TAG}: $([ "$published" = true ] && echo 'published' || echo 'dry run')"

# Suggestions
SUGGESTIONS='[]'
if [ "$published" = true ] && [ -n "$release_url" ]; then
  add_suggestion "release:create" "Release ${TAG} created" "{\"url\": \"${release_url}\"}" "medium"
fi

write_envelope "release" "success" "$SUMMARY"

echo "status=success" >> "$GITHUB_OUTPUT"
echo "summary=${SUMMARY}" >> "$GITHUB_OUTPUT"
echo "release_url=${release_url:-}" >> "$GITHUB_OUTPUT"
