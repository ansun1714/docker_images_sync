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

# 源镜像清单里是否有指定的 linux 架构
has_platform() {
  echo "$1" | jq -e --arg a "$2" \
    '[.manifests[]? | select(.platform.os=="linux" and .platform.architecture==$a)] | length > 0' >/dev/null
}

sync_one() {
  local src="$1" dst="$2" raw dst_repo tag a df d
  local digests=()

  raw=$(skopeo inspect --raw "docker://$src") || return 1

  # 单架构镜像：直接复制
  if ! echo "$raw" | jq -e '.manifests' >/dev/null 2>&1; then
    echo "    单架构镜像，直接复制"
    skopeo copy --retry-times 3 "docker://$src" "docker://$dst" || return 1
    return 0
  fi

  dst_repo="${dst%:*}"
  tag="${dst##*:}"
  df=$(mktemp)

  # 逐个架构复制（只复制真实镜像，不带 BuildKit 的证明附件）
  for a in $ARCHS; do
    if ! has_platform "$raw" "$a"; then
      echo "    (源镜像没有 linux/$a，已跳过)"
      continue
    fi
    echo "    复制 linux/$a ..."
    skopeo copy --retry-times 3 --override-os linux --override-arch "$a" \
      --digestfile "$df" "docker://$src" "docker://${dst_repo}:${tag}-${a}" \
      || { rm -f "$df"; return 1; }
    d=$(cat "$df")
    digests+=("${dst_repo}@${d}")
  done
  rm -f "$df"

  [ "${#digests[@]}" -gt 0 ] || { echo "    没有可同步的架构"; return 1; }

  # 在阿里云端把各架构合成一个多架构 tag
  echo "    合成多架构清单 -> $dst"
  docker buildx imagetools create -t "$dst" "${digests[@]}" || return 1
}

total=0; failed=0; failed_list=""

while IFS= read -r image || [ -n "$image" ]; do
  image="${image//[$'\r ']/}"
  [[ -z "$image" || "$image" =~ ^# ]] && continue
  total=$((total + 1))

  # 没写 tag 的补 :latest
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
