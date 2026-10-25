#!/bin/bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "用法: $0 <images_file> <docker_registry> <docker_namespace>"
  exit 1
fi

IMAGES_FILE="$1"
TARGET_REGISTRY="$2"
TARGET_NAMESPACE="$3"

[ -f "$IMAGES_FILE" ] || { echo "错误：$IMAGES_FILE 不存在"; exit 1; }

command -v skopeo >/dev/null || {
  sudo apt-get update -qq && sudo apt-get install -y -qq skopeo
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

  # 打印源镜像支持的平台，方便在日志里确认
  skopeo inspect --raw "docker://$image" 2>/dev/null \
    | jq -r '.manifests[]?.platform | select(.os!="unknown") | "    平台: \(.os)/\(.architecture)"' \
    || true

  target="${TARGET_REGISTRY}/${TARGET_NAMESPACE}/${image##*/}"

  if skopeo copy --all --retry-times 3 "docker://$image" "docker://$target"; then
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
