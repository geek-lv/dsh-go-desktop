#!/usr/bin/env bash
# 生成桌面（Windows / Linux）本机引擎运行时包，供 DSH Go 桌面版内置。
#
# 与 runtime/build-runtime-macos.sh 同源：运行时 = 官方 Node + npm ci 装好的 DSH 树
# + pnpm + dsh-go-bridge + runtime/patches 里按版本钉死的 dsh 补丁。
# 与 Android 版 runtime/build-runtime.sh 的差别：不需要 PRoot / Ubuntu rootfs。
#
#   bash runtime/build-runtime-desktop.sh --platform windows            # x64，输出 app/assets/runtime-windows/
#   bash runtime/build-runtime-desktop.sh --platform linux              # x64，输出 app/assets/runtime-linux/
#   bash runtime/build-runtime-desktop.sh --platform windows --out /tmp/x
#   bash runtime/build-runtime-desktop.sh --platform windows --clean    # 丢掉缓存重新下载
#
# 产物（每个平台一份）：
#   $OUT/runtime-x64.tar.gz     （顶层目录 runtime/）
#   $OUT/manifest.json          （版本、sha256、启动 argv，按平台不同）
#
# 缓存：runtime/.cache/desktop-<platform>/（Node 发行版、npm 树、npm cache），可重复使用。
#
# Windows 宿主注意：本脚本是 bash 脚本，Windows 上请用 Git Bash 运行（自带 curl /
# unzip / tar / sha256sum）；python3 若指向 Microsoft Store 的占位程序会失败，
# 用 PYTHON=/c/Program\ Files/Python312/python.exe 指定真正的解释器。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PLATFORM=""
ARCH="x64"
OUT=""
clean=0

usage() { sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) PLATFORM="${2:-}"; shift 2 ;;
    --platform=*) PLATFORM="${1#*=}"; shift ;;
    --arch) ARCH="${2:-}"; shift 2 ;;
    --arch=*) ARCH="${1#*=}"; shift ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --out=*) OUT="${1#*=}"; shift ;;
    --clean) clean=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "build-runtime-desktop: 未知参数 $1" >&2; exit 2 ;;
  esac
done

die() { printf 'build-runtime-desktop: %s\n' "$*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }
warn() { printf 'build-runtime-desktop: 警告：%s\n' "$*" >&2; }

case "$PLATFORM" in
  windows | linux) ;;
  "") usage; die "缺少 --platform windows|linux" ;;
  *) die "--platform 只能是 windows 或 linux（收到 $PLATFORM）" ;;
esac

DSH_VERSION="${DSH_VERSION:-0.2.2-rc.1}"
NODE_VERSION="${NODE_VERSION:-24.22.1}"
PNPM_VERSION="${PNPM_VERSION:-11.28.5}"

case "$ARCH" in
  x64) NODE_ARCH=x64; NPM_CPU=x64 ;;
  # 保留扩展点：Node 官方 win-arm64 / linux-arm64 都存在，但需自行验证 DSH 依赖树。
  arm64) NODE_ARCH=arm64; NPM_CPU=arm64 ;;
  *) die "--arch 只能是 x64 或 arm64（收到 $ARCH）" ;;
esac

CACHE="$HERE/.cache/desktop-$PLATFORM"
WORK="$HERE/.work/desktop-$PLATFORM"
STAGE="$WORK/stage"
OUT="${OUT:-$ROOT/app/assets/runtime-$PLATFORM}"

# npm 的 --os / --libc：决定 optionalDependencies 里哪些平台包被装上。
case "$PLATFORM" in
  windows) NPM_OS=win32; NPM_LIBC=""; NODE_DIST="win-$NODE_ARCH"; EXE_SUFFIX=".exe" ;;
  linux) NPM_OS=linux; NPM_LIBC="glibc"; NODE_DIST="linux-$NODE_ARCH"; EXE_SUFFIX="" ;;
esac

# Windows 上把 MSYS 路径翻成 Windows 路径再交给原生程序（npm.cmd / node.exe）。
# cygpath 只在 Git Bash/msys 里存在；Linux 上原样返回。
winpath() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}
is_windows_host() { case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) return 0 ;; *) return 1 ;; esac; }

# 真正能跑的解释器：Windows 的 python3 常是 Store 占位程序，-c 直接失败。
pick_python() {
  local cand
  for cand in "${PYTHON:-}" python3 python; do
    [[ -n "$cand" ]] || continue
    if "$cand" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; then
      printf '%s' "$cand"
      return 0
    fi
  done
  # Git Bash 里 $PATH 上的 python 也可能是占位程序，最后试一次常见安装位置。
  for cand in "/c/Program Files/Python312/python.exe" "/c/Program Files/Python311/python.exe" /usr/bin/python3; do
    if [[ -x "$cand" ]] && "$cand" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

PY="$(pick_python)" || die "找不到可用的 Python 3.9+（试过 $PYTHON / python3 / python）；用 PYTHON=/path/to/python 指定"
command -v curl >/dev/null || die "需要 curl"
command -v sha256sum >/dev/null || die "需要 sha256sum（Git Bash 自带）"
command -v tar >/dev/null || die "需要 tar（Git Bash 自带）"
if [[ "$PLATFORM" == windows ]]; then
  command -v unzip >/dev/null || die "解压 win-x64.zip 需要 unzip（Git Bash 自带）"
else
  tar --help 2>/dev/null | grep -q -- '-J' || warn "tar 可能不支持 .tar.xz（需要 xz）"
fi

mkdir -p "$CACHE" "$WORK" "$OUT"
if ((clean)); then
  say "清理缓存"
  rm -rf "$CACHE" "$WORK"
  mkdir -p "$CACHE" "$WORK"
fi

# ---------------------------------------------------------------------------
# 1. Node 发行版
#    Windows：win-x64.zip，解包后 node.exe / npm.cmd / npx.cmd 在**根目录**；
#    Linux  ：linux-x64.tar.xz，解包后 bin/node、bin/npm（指向 lib/node_modules/npm）。

NODE_DIR="$CACHE/node"
node_exe() { printf '%s' "$NODE_DIR/node${EXE_SUFFIX}"; }
node_npm() { if [[ "$PLATFORM" == windows ]]; then printf '%s' "$NODE_DIR/npm.cmd"; else printf '%s' "$NODE_DIR/bin/npm"; fi; }

if [[ ! -x "$NODE_DIR/node${EXE_SUFFIX}" ]]; then
  say "下载 Node $NODE_VERSION ($NODE_DIST)"
  if [[ "$PLATFORM" == windows ]]; then
    archive="node-v$NODE_VERSION-$NODE_DIST.zip"
    sums="SHASUMS256.txt"
  else
    archive="node-v$NODE_VERSION-$NODE_DIST.tar.xz"
    sums="SHASUMS256.txt"
  fi
  if [[ ! -f "$CACHE/$archive" ]]; then
    for url in \
      "https://npmmirror.com/mirrors/node/v$NODE_VERSION/$archive" \
      "https://nodejs.org/dist/v$NODE_VERSION/$archive"; do
      if curl -fL --retry 2 --connect-timeout 20 -o "$CACHE/$archive.part" "$url"; then
        mv "$CACHE/$archive.part" "$CACHE/$archive"
        break
      fi
    done
    [[ -f "$CACHE/$archive" ]] || die "下载 Node 失败（$NODE_DIST）"
  fi
  # 校验官方 SHASUMS256.txt（拿不到就跳过并警告，不静默通过）
  if curl -fsSL --connect-timeout 20 -o "$CACHE/$sums" "https://nodejs.org/dist/v$NODE_VERSION/$sums"; then
    want="$(awk -v f="$archive" '$2==f {print $1}' "$CACHE/$sums")"
    got="$(sha256sum "$CACHE/$archive" | cut -d' ' -f1)"
    if [[ -n "$want" && "$want" != "$got" ]]; then
      rm -f "$CACHE/$archive"
      die "$archive sha256 与 nodejs.org 的 SHASUMS256.txt 不符（got $got want $want）"
    fi
    [[ -n "$want" ]] || warn "SHASUMS256.txt 里没有 $archive，跳过校验"
  else
    warn "取不到 SHASUMS256.txt，跳过 Node 发行版校验"
  fi

  tmp="$CACHE/node.tmp"
  rm -rf "$tmp" && mkdir -p "$tmp"
  if [[ "$PLATFORM" == windows ]]; then
    # zip 里有一层 node-vX-win-x64/，用 unzip 剥掉
    unzip -q "$CACHE/$archive" -d "$tmp.raw"
    inner="$(find "$tmp.raw" -maxdepth 1 -mindepth 1 -type d | head -1)"
    [[ -n "$inner" ]] || die "zip 结构不认识（找不到顶层目录）"
    shopt -s dotglob
    mv "$inner"/* "$tmp"/
    shopt -u dotglob
    rm -rf "$tmp.raw"
  else
    tar -xJf "$CACHE/$archive" -C "$tmp" --strip-components=1
  fi
  rm -rf "$NODE_DIR" && mv "$tmp" "$NODE_DIR"
fi
"$(node_exe)" --version

# ---------------------------------------------------------------------------
# 2. DSH 依赖树（npm ci，锁文件固定在 runtime/locks/dsh-<version>/）

DSH_DIR="$CACHE/dsh"
node_modules_dir="$DSH_DIR/node_modules"
if [[ ! -d "$node_modules_dir/@deepseek-ai/dsh" ]] || [[ -f "$WORK/needs-reinstall" ]]; then
  say "安装 DSH $DSH_VERSION（npm ci，os=$NPM_OS cpu=$NPM_CPU）"
  rm -rf "$DSH_DIR"
  mkdir -p "$DSH_DIR"
  cp "$HERE/locks/dsh-$DSH_VERSION/package.json" "$HERE/locks/dsh-$DSH_VERSION/package-lock.json" "$DSH_DIR/"
  # 空 user/global npmrc：宿主的 npm 配置不参与，跟 macOS 脚本一致
  : >"$WORK/empty-user-npmrc"
  : >"$WORK/empty-global-npmrc"
  npm_flags=(
    --registry="https://registry.npmmirror.com"
    --cache "$(winpath "$CACHE/npm")"
    --userconfig "$(winpath "$WORK/empty-user-npmrc")"
    --globalconfig "$(winpath "$WORK/empty-global-npmrc")"
    --os="$NPM_OS" --cpu="$NPM_CPU"
    --ignore-scripts --no-audit --no-fund --update-notifier=false --loglevel=error
  )
  [[ -n "$NPM_LIBC" ]] && npm_flags+=(--libc="$NPM_LIBC")
  # npm 在 Windows 上是 npm.cmd：cd 进去跑，避免把 MSYS 路径当 cwd 传过去。
  (cd "$(winpath "$DSH_DIR")" && "$(winpath "$(node_npm)")" ci "${npm_flags[@]}")
  rm -f "$WORK/needs-reinstall"
fi

installed="$("$PY" -X utf8 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$node_modules_dir/@deepseek-ai/dsh/package.json")"
[[ "$installed" == "$DSH_VERSION" ]] || die "装上的 dsh $installed != $DSH_VERSION"

# ---------------------------------------------------------------------------
# 3. pnpm（插件安装用），装进 Node 目录
#    Windows 落到 $NODE_DIR/pnpm.cmd；Linux 落到 $NODE_DIR/bin/pnpm

if [[ "$PLATFORM" == windows ]]; then
  pnpm_bin="$NODE_DIR/pnpm.cmd"
else
  pnpm_bin="$NODE_DIR/bin/pnpm"
fi
if [[ ! -e "$pnpm_bin" ]]; then
  say "安装 pnpm $PNPM_VERSION"
  : >"$WORK/empty-user-npmrc"
  : >"$WORK/empty-global-npmrc"
  (cd "$(winpath "$CACHE")" && "$(winpath "$(node_npm)")" install -g "pnpm@$PNPM_VERSION" \
    --prefix "$(winpath "$NODE_DIR")" \
    --registry="https://registry.npmmirror.com" --cache "$(winpath "$CACHE/npm")" \
    --userconfig "$(winpath "$WORK/empty-user-npmrc")" --globalconfig "$(winpath "$WORK/empty-global-npmrc")" \
    --no-audit --no-fund --loglevel=error)
fi
[[ -e "$pnpm_bin" ]] || die "pnpm 没装到 $pnpm_bin"

# ---------------------------------------------------------------------------
# 4. 组装

say "组装运行时"
rm -rf "$STAGE"
mkdir -p "$STAGE/runtime"
cp -R "$NODE_DIR" "$STAGE/runtime/node"
cp -R "$DSH_DIR" "$STAGE/runtime/dsh"
cp -R "$HERE/bridge/dsh-go-bridge" "$STAGE/runtime/bridge"
mkdir -p "$STAGE/runtime/etc/dsh-app" "$STAGE/runtime/home/.dsh" "$STAGE/runtime/tmp"
# Windows 上没有 POSIX 权限位；Git Bash 的 chmod 只影响模拟位，失败不影响产物。
chmod 700 "$STAGE/runtime/home" "$STAGE/runtime/home/.dsh" 2>/dev/null || true

say "应用 dsh 补丁"
# 与 Android/macOS 用同一条严格补丁链（runtime/patches，按 DSH 版本钉死）。
# 补丁链走 tools/dsh-patch（Node）：构建机与用户机是同一份实现，不需要 Python。
command -v node >/dev/null || die "需要 node（补丁链用 tools/dsh-patch）"
node "$ROOT/tools/dsh-patch/cli.mjs" apply \
  --prefix "$STAGE/runtime/dsh" --dsh-version "$DSH_VERSION" --patches "$HERE/patches" \
  --companion "$HERE/session-deletion" | sed 's/^/  /'

bridge_version="$("$PY" -X utf8 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$HERE/bridge/dsh-go-bridge/package.json")"

if [[ "$PLATFORM" == windows ]]; then
  runtime_version="desktop-win-r1"
  platform_tag="win32-x64"
  node_rel="node/node.exe"
else
  runtime_version="desktop-linux-r1"
  platform_tag="linux-x64"
  node_rel="node/bin/node"
fi

cat >"$STAGE/runtime/etc/dsh-app/runtime.json" <<EOF
{
  "runtimeVersion": "$runtime_version",
  "platform": "$platform_tag",
  "dshVersion": "$DSH_VERSION",
  "nodeVersion": "$NODE_VERSION",
  "pnpmVersion": "$PNPM_VERSION",
  "bridgeVersion": "$bridge_version"
}
EOF

# ---------------------------------------------------------------------------
# 5. 打包 + manifest

say "打包（gzip）"
archive="runtime-$ARCH.tar.gz"
rm -f "$OUT/$archive"
tar -czf "$OUT/$archive" -C "$STAGE" runtime
bytes="$(wc -c <"$OUT/$archive" | tr -d ' ')"
sha="$(sha256sum "$OUT/$archive" | cut -d' ' -f1)"
unpacked="$(du -sk "$STAGE/runtime" | cut -f1)"

say "写 manifest"
"$PY" -X utf8 - "$OUT" "$PLATFORM" "$ARCH" "$archive" "$bytes" "$sha" "$((unpacked * 1024))" \
  "$DSH_VERSION" "$NODE_VERSION" "$PNPM_VERSION" "$runtime_version" "$platform_tag" "$node_rel" <<'PY'
import json, os, sys

(out, platform, arch, archive, size, sha, unpacked,
 dsh, node, pnpm, runtime_version, platform_tag, node_rel) = sys.argv[1:14]

if platform == "windows":
    # Windows：node.exe 在运行时根目录（不是 bin/node）；PATH 必须是在系统 PATH
    # *前面追加* 运行时 node 目录，而不是整体替换（conpty / system32 依赖它）。
    launch_env = {
        "TMPDIR": "{RUNTIME}/tmp",
        "DSH_HOME": "{HOME}/.dsh",
    }
    path_prepend = ["{RUNTIME}/node"]
    exe_suffix = ".exe"
else:
    # Linux：与 macOS 相同的布局和 PATH 替换语义。
    launch_env = {
        "HOME": "{HOME}",
        "DSH_HOME": "{HOME}/.dsh",
        "PATH": "{RUNTIME}/node/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": "{RUNTIME}/tmp",
        "LANG": "en_US.UTF-8",
        "TERM": "xterm-256color",
        "NODE_OPTIONS": "--dns-result-order=ipv4first",
    }
    path_prepend = []
    exe_suffix = ""

manifest = {
    "runtimeVersion": runtime_version,
    "abi": arch,
    "platform": platform_tag,
    "archive": f"assets/runtime-{platform}/{archive}",
    "archiveBytes": int(size),
    "archiveSha256": sha,
    "uncompressedBytes": int(unpacked),
    "dshVersion": dsh,
    "nodeVersion": node,
    "pnpmVersion": pnpm,
    # 和 macOS manifest 的 launch 结构保持同形：宿主替换 {RUNTIME}/{HOME}/{PORT}/
    # {DSH_PROFILE_ARGS}，argv[0] 必须是真正的可执行文件（Windows 上是 node.exe）。
    "launch": {
        "argv": [
            "{RUNTIME}/" + node_rel,
            "{RUNTIME}/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js",
            "{DSH_PROFILE_ARGS}",
            "--host", "127.0.0.1",
            "--port", "{PORT}",
            "--no-open",
        ],
        "env": {},
        "profile": "web",
        "patch": "{RUNTIME}/etc/dsh-app/dsh-web.patch.yml",
        "tokenLine": {
            "regex": "^dsh web: (http://127\\.0\\.0\\.1:[0-9]+/)\\?token=([A-Za-z0-9_-]+)",
        },
    },
    "launchEnv": launch_env,
    "exeSuffix": exe_suffix,
}
if path_prepend:
    manifest["pathPrepend"] = path_prepend

with open(os.path.join(out, "manifest.json"), "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
print(json.dumps({k: manifest[k] for k in
                  ("runtimeVersion", "platform", "archiveBytes", "dshVersion", "nodeVersion", "pnpmVersion")},
                 indent=2))
PY

say "校验 manifest"
"$PY" -X utf8 - "$OUT/manifest.json" "$DSH_VERSION" "$platform_tag" "$node_rel" "$OUT/$archive" <<'PY'
import hashlib, json, os, sys

path, dsh, platform_tag, node_rel, archive = sys.argv[1:6]
m = json.load(open(path, encoding="utf-8"))
assert m["dshVersion"] == dsh, (m["dshVersion"], dsh)
assert m["platform"] == platform_tag, (m["platform"], platform_tag)
assert m["launch"]["argv"][0] == "{RUNTIME}/" + node_rel, m["launch"]["argv"][0]
assert m["launch"]["argv"][1].endswith("dsh/lib/bin.js"), m["launch"]["argv"][1]
h = hashlib.sha256(open(archive, "rb").read()).hexdigest()
assert h == m["archiveSha256"], (h, m["archiveSha256"])
assert os.path.getsize(archive) == m["archiveBytes"]
print(f"manifest ok: {m['runtimeVersion']} / DSH {m['dshVersion']} / {m['platform']}")
PY

say "完成：$OUT/$archive（$((bytes / 1048576)) MiB，解包 $((unpacked / 1024)) MiB）"
