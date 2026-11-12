#!/usr/bin/env bash
# 对拍：同一份 pristine DSH 前缀，分别用 Python 版（runtime/lib/rtbuild.py）和
# Node 版（tools/dsh-patch/cli.mjs）打同一套补丁，逐文件比对 sha256，并要求
# `record` 写出的 pins.json 完全一致。
#
#   bash tools/dsh-patch/parity.sh [pristine-prefix] [dsh-version]
#
# 默认用桌面构建缓存里的 pristine 树（`runtime/.cache/desktop-windows/dsh`）与
# `runtime/locks/dsh-<ver>` 里登记的最新版本。
#
# 只复制补丁实际触碰的文件，所以对拍很快（不必复制 548 MB 的整棵树）。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PATCHES="$REPO/runtime/patches"
COMPANION="$REPO/runtime/session-deletion"

PRISTINE="${1:-$REPO/runtime/.cache/desktop-windows/dsh}"
VERSION="${2:-$(ls "$REPO/runtime/locks" | sed -n 's/^dsh-//p' | sort -V | tail -1)}"

[[ -d "$PRISTINE" ]] || { echo "找不到 pristine 树：$PRISTINE" >&2; exit 2; }
[[ -d "$PATCHES" ]] || { echo "找不到补丁目录：$PATCHES" >&2; exit 2; }

PY="${PYTHON:-python}"
command -v "$PY" >/dev/null || { echo "需要 Python（可 PYTHON=... 指定）" >&2; exit 2; }
command -v node >/dev/null || { echo "需要 node" >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/A" "$WORK/B"

echo "== 收集补丁触碰的文件"
mapfile -t FILES < <(grep -h '^+++ b/' "$PATCHES"/*.diff | sed 's|^+++ b/||' | sort -u)
printf '  %s 个文件\n' "${#FILES[@]}"

for rel in "${FILES[@]}"; do
  src="$PRISTINE/$rel"
  [[ -f "$src" ]] || { echo "pristine 树里缺 $rel（树不完整？）" >&2; exit 2; }
  mkdir -p "$WORK/A/$(dirname "$rel")" "$WORK/B/$(dirname "$rel")"
  cp "$src" "$WORK/A/$rel"
  cp "$src" "$WORK/B/$rel"
done

echo "== Python 版（rtbuild.py patch-dsh）"
PYTHONIOENCODING=utf-8 "$PY" -X utf8 -I "$REPO/runtime/lib/rtbuild.py" patch-dsh \
  --prefix "$WORK/A" --dsh-version "$VERSION" --patches "$PATCHES" | tail -3

echo "== Node 版（tools/dsh-patch/cli.mjs apply）"
node "$HERE/cli.mjs" apply --prefix "$WORK/B" --patches "$PATCHES" --dsh-version "$VERSION" \
  --companion "$COMPANION" --quiet | tail -3

echo "== 比对产物哈希"
fail=0
for rel in "${FILES[@]}" "node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/dsh-go-deletion.mjs"; do
  a="$WORK/A/$rel"; b="$WORK/B/$rel"
  [[ -f "$a" && -f "$b" ]] || { echo "  两边文件不全：$rel" >&2; fail=1; continue; }
  ha="$(sha256sum "$a" | cut -d' ' -f1)"; hb="$(sha256sum "$b" | cut -d' ' -f1)"
  [[ "$ha" == "$hb" ]] || { echo "  不一致：$rel" >&2; fail=1; }
done
if ((fail)); then
  echo "对拍失败：产物不同" >&2
  exit 1
fi
echo "  产物逐字节一致（$(( ${#FILES[@]} + 1 )) 个文件）"

echo "== 比对 record 写出的 pins"
cp -R "$PATCHES" "$WORK/pins-py"
cp -R "$PATCHES" "$WORK/pins-node"
# 从 pristine 复制一份未打补丁的树给 record 用（record 会把补丁真打上）
mkdir -p "$WORK/R"
for rel in "${FILES[@]}"; do
  mkdir -p "$WORK/R/$(dirname "$rel")"
  cp "$PRISTINE/$rel" "$WORK/R/$rel"
done
PYTHONIOENCODING=utf-8 "$PY" -X utf8 -I "$REPO/runtime/lib/rtbuild.py" patch-dsh \
  --prefix "$WORK/R" --dsh-version "$VERSION" --patches "$WORK/pins-py" --record >/dev/null
rm -rf "$WORK/R" && mkdir -p "$WORK/R"
for rel in "${FILES[@]}"; do
  mkdir -p "$WORK/R/$(dirname "$rel")"
  cp "$PRISTINE/$rel" "$WORK/R/$rel"
done
node "$HERE/cli.mjs" record --prefix "$WORK/R" --patches "$WORK/pins-node" --dsh-version "$VERSION" \
  --companion "$COMPANION" --quiet >/dev/null

# 行尾不算差异：Python 在 Windows 上以文本模式写 pins.json（CRLF），Node 按仓库约定写 LF
# （runtime/patches/pins.json 本身就是 LF）。内容必须完全一致。
if diff --strip-trailing-cr -q "$WORK/pins-py/pins.json" "$WORK/pins-node/pins.json" >/dev/null; then
  echo "  pins.json 内容完全一致（行尾差异已忽略）"
else
  echo "pins.json 不一致：" >&2
  diff --strip-trailing-cr "$WORK/pins-py/pins.json" "$WORK/pins-node/pins.json" | head -40 >&2
  exit 1
fi

echo
echo "对拍通过：Node 版与 Python 版结果一致（dsh $VERSION）"
