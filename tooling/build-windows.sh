#!/usr/bin/env bash
# 构建 Windows 版 DSH Go：Release 可执行文件 + 一个免安装 zip（解压即用）。
#
#   bash tooling/build-windows.sh            # 输出 app/build/windows/dsh-go-windows-<ver>-x64.zip
#   bash tooling/build-windows.sh --skip-zip # 只编译
#
# 前置：
#   - Flutter 3.47.x（PATH 里有 flutter，或用 FLUTTER=... 指定）
#   - Visual Studio 2022（含 C++ 桌面工作负载 **与 ATL 组件**：flutter_secure_storage
#     的 Windows 实现用到 CString/CW2A，缺 ATL 时编译会报 atlstr.h 找不到）
#   - 运行时归档已经生成：bash runtime/build-runtime-desktop.sh --platform windows
#
# 在 Git Bash / MSYS 下运行（GitHub windows runner 默认就是 Git Bash）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/app"
skip_zip=0
for arg in "$@"; do
  case "$arg" in
    --skip-zip) skip_zip=1 ;;
    -h | --help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "build-windows: 未知参数 $arg" >&2; exit 2 ;;
  esac
done

die() { printf 'build-windows: %s\n' "$*" >&2; exit 1; }

if [[ -n "${FLUTTER:-}" ]]; then
  flutter="$FLUTTER"
elif command -v flutter >/dev/null; then
  flutter="$(command -v flutter)"
elif [[ -x "$ROOT/.tools/flutter/bin/flutter" ]]; then
  flutter="$ROOT/.tools/flutter/bin/flutter"
else
  die "找不到 flutter。装 Flutter 3.47.x，或用 FLUTTER=/path/to/flutter 指定"
fi

version="$(grep -m1 '^version:' "$APP/pubspec.yaml" | awk '{print $2}' | cut -d+ -f1)"
[[ -n "$version" ]] || die "读不到 app/pubspec.yaml 的 version"

# 运行时归档必须已经构建（184 MB，不在 git 里）。缺了就打进一个不能装引擎的包——不干。
manifest="$APP/assets/runtime-windows/manifest.json"
archive="$APP/assets/runtime-windows/runtime-x64.tar.gz"
[[ -f "$archive" ]] || die "缺少运行时归档 $archive：先跑 bash runtime/build-runtime-desktop.sh --platform windows"
grep -q '"runtimeVersion": "desktop-win-r1"' "$manifest" || die "manifest.json 的 runtimeVersion 不是 desktop-win-r1"
echo "runtime archive: $(du -h "$archive" | cut -f1)"

# ATL 是 flutter_secure_storage_windows 的硬依赖；提前说清楚，别等编译到一半才报。
atl_hint="$(ls "/c/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC"/*/atlmfc/include/atlstr.h 2>/dev/null | head -1 || true)"
[[ -n "$atl_hint" ]] || warn_atl=1
if [[ -n "${warn_atl:-}" ]]; then
  echo "build-windows: 警告：没找到 atlstr.h。若编译报 atlstr.h not found，请在 VS Installer 里加" >&2
  echo "               Microsoft.VisualStudio.Component.VC.ATL 组件。" >&2
fi

echo "== flutter build windows --release"
(cd "$APP" && "$flutter" build windows --release)

out="$APP/build/windows/x64/runner/Release"
[[ -f "$out/dsh_app.exe" ]] || die "没有产物 $out/dsh_app.exe"

if ((skip_zip)); then
  echo "跳过打包：$out"
  exit 0
fi

echo "== 打包 zip"
target="$APP/build/windows/dsh-go-windows-$version-x64.zip"
mkdir -p "$(dirname "$target")"
rm -f "$target"
# Windows runner 上没有 zip 命令，用 PowerShell（本地 Git Bash 同样可用）。
# 必须传 **Windows 路径**：MSYS 的 /c/... 形式 PowerShell 不认（否则报 ArchiveCmdletPathNotFound）。
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
win_out="$(winpath "$out")"
win_target="$(winpath "$target")"
powershell -NoProfile -Command "Compress-Archive -Path '$win_out\*' -DestinationPath '$win_target' -CompressionLevel Optimal -Force"
[[ -f "$target" ]] || die "打包失败：$target"

echo "== 校验和"
(cd "$(dirname "$target")" && sha256sum "$(basename "$target")" | tee SHA256SUMS)
ls -lh "$target"
echo "ZIP: $target"
