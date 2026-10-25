#!/bin/bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "用法: $0 <images_file> <docker_registry> <docker_namespace>"
  exit 1
fi

IMAGES_FILE="$1"
TARGET_REGISTRY="$2"
TARGET_NAMESPACE="$3"

# 需要同步的架构（空格分隔）
ARCHS="amd64 arm64"

[ -f "$IMAGES_FILE" ] || { echo "错误：$IMAGES_FILE 不存在"; exit 1; }

command -v skopeo >/dev/null || {
  sudo apt-get update -qq && sudo apt-get install -y -qq skopeo
}

# 只挑选真实的 linux 架构镜像，跳过 BuildKit 附带的 provenance/SBOM 证明清单
pick_digests() {
  local raw="$1" repo="$2" a d
  for a in $ARCHS; do
    d=$(echo "$raw" | jq -r --arg a "$a" \
      '[.manifests[]? | select(.platform.os=="linux" and .platform.architecture==$a)][0].digest // empty')
    if [ -n "$d" ]; then
      echo "${repo}@${d}"
    else
      echo "    (源镜像没有 linux/$a，已跳过)" >&2
    fi
  done
}

sync_one() {
  local src="$1" dst="$2" raw repo
  raw=$(skopeo inspect --raw "docker://$src") || return 1

  # 单架构镜像：直接复制
  if ! echo "$raw" | jq -e '.manifests' >/dev/null 2>&1; then
    echo "    单架构镜像，直接复制"
    skopeo copy --retry-times 3 "docker://$src" "docker://$dst"
    return
  fi

  if [[ "$src" == *@* ]]; then repo="${src%@*}"; else repo="${src%:*}"; fi

  local digests=()
  while IFS= read -r line; do
    [ -n "$line" ] && digests+=("$line")
  done < <(pick_digests "$raw" "$repo")

  [ "${#digests[@]}" -gt 0 ] || { echo "    没有可同步的架构"; return 1; }

  docker buildx imagetools create -t "$dst" "${digests[@]}"
}

total=0; failed=0; failed_list=""

while IFS= read -r image || [ -n "$image" ]; do
  image="${image//[$'\r ']/}"
  [[ -z "$image" || "$image" =~ ^# ]] && continue
  total=$((total + 1))

  last="${image##*/}"
  [[ "$last" == *:* || "$last" == *@* ]] || image="${image}:latest"

  echo "=========================================="
  echo ">>> (${total}) $image"

  target="${TARGET_REGISTRY}/${TARGET_NAMESPACE}/${image##*/}"

  if sync_one "$image" "$target"; then
    echo "✅ 完成 -> $target"
  else
    echo "❌ 失败: $image"
    failed=$((failed + 1)); failed_list="$failed_list $image"
  fi
done < "$IMAGES_FILE"

echo "=========================================="
echo "总数: $total  失败: $failed"
[ $failed -eq 0 ] || { echo "失败列表:$failed_list"; exit 1; }
echo "✅ 全部成功"
