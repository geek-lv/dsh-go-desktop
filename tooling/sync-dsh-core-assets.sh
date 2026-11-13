#!/usr/bin/env bash
# 把补丁链同步成 App 资源：tools/dsh-patch/*.mjs + runtime/patches/* → app/assets/dsh-core/。
#
# 为什么要进资源包：安装/更新 DSH 核心发生在**用户机**上，那里没有 Python，也没有仓库；
# 补丁链必须是 App 自带的一份（Node 运行时由本机引擎提供）。
#
#   bash tooling/sync-dsh-core-assets.sh          # 同步
#   bash tooling/sync-dsh-core-assets.sh --check  # 只检查是否已同步（CI 用）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

SRC_TOOL="$ROOT/tools/dsh-patch"
SRC_PATCH="$ROOT/runtime/patches"
SRC_LOCKS="$ROOT/runtime/locks"
SRC_COMPANION="$ROOT/runtime/session-deletion"
DEST="$ROOT/app/assets/dsh-core"

check=0
[[ "${1:-}" == "--check" ]] && check=1

mkdir -p "$DEST/patches" "$DEST/locks" "$DEST/session-deletion"

if ((check)); then
  drift=0
  for f in cli.mjs diff.mjs apply.mjs; do
    cmp -s "$SRC_TOOL/$f" "$DEST/$f" || { echo "不同步：$f" >&2; drift=1; }
  done
  for f in "$SRC_PATCH"/*.diff "$SRC_PATCH/pins.json"; do
    cmp -s "$f" "$DEST/patches/$(basename "$f")" || { echo "不同步：$(basename "$f")" >&2; drift=1; }
  done
  cmp -s "$SRC_COMPANION/core.mjs" "$DEST/session-deletion/core.mjs" || { echo "不同步：session-deletion/core.mjs" >&2; drift=1; }
  for dir in "$SRC_LOCKS"/dsh-*; do
    version="$(basename "$dir")"
    for f in package.json package-lock.json; do
      cmp -s "$dir/$f" "$DEST/locks/$version/$f" || { echo "不同步：$version/$f" >&2; drift=1; }
    done
  done
  # 反向：资源里有但源里已经删掉的
  for f in "$DEST/patches"/*; do
    [[ -e "$SRC_PATCH/$(basename "$f")" ]] || { echo "多余：$(basename "$f")" >&2; drift=1; }
  done
  ((drift)) && { echo "app/assets/dsh-core 需要重新同步" >&2; exit 1; }
  echo "app/assets/dsh-core 已同步"
  exit 0
fi

cp "$SRC_TOOL/cli.mjs" "$SRC_TOOL/diff.mjs" "$SRC_TOOL/apply.mjs" "$DEST/"
rm -f "$DEST/patches"/*
cp "$SRC_PATCH"/*.diff "$SRC_PATCH/pins.json" "$DEST/patches/"
# 会话删除补丁的伴生实现（补丁链应用时会把它拷进 dsh 树里）
cp "$SRC_COMPANION/core.mjs" "$DEST/session-deletion/core.mjs"
# 锁文件：审查过的版本靠它复现同一棵依赖树（补丁打在具体版本的文件上，
# 没有锁就会装上浮动的依赖，补丁对不上）。
rm -rf "$DEST/locks"; mkdir -p "$DEST/locks"
for dir in "$SRC_LOCKS"/dsh-*; do
  version="$(basename "$dir")"
  mkdir -p "$DEST/locks/$version"
  cp "$dir/package.json" "$dir/package-lock.json" "$DEST/locks/$version/"
done
echo "已同步 $(ls "$DEST/patches" | wc -l) 个补丁 + $(ls "$DEST/locks" | wc -l) 套锁文件到 app/assets/dsh-core"
