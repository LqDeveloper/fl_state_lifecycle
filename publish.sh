#!/usr/bin/env bash
#
# 发布 fl_state_lifecycle 到 pub.dev
#
# 用法:
#   ./publish.sh          完整发布流程:analyze → test → dry-run → 确认 → publish(可选打 git tag)
#   ./publish.sh --check  只跑检查(analyze / test / dry-run),不真正发布
#
# 前置条件:
#   - flutter 命令可用(https://flutter.dev)
#   - 在包根目录运行
#
set -euo pipefail

cd "$(dirname "$0")"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info() { printf "${GREEN}[publish]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[publish]${NC} %s\n" "$*"; }
die()  { printf "${RED}[publish]${NC} %s\n" "$*" >&2; exit 1; }

CHECK_ONLY=false
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=true

# --- 0. 前置检查 -------------------------------------------------------------
command -v flutter >/dev/null 2>&1 || die "未找到 flutter,请先安装: https://flutter.dev"
[[ -f pubspec.yaml ]] || die "请在包根目录运行(未找到 pubspec.yaml)"

# --- 1. git 状态检查 ---------------------------------------------------------
if [[ ! -d .git ]]; then
  warn "不是 git 仓库,发布后无法打 tag(不影响发布本身)"
elif ! git diff --quiet || ! git diff --cached --quiet; then
  warn "工作区有未提交的修改,发布建议从干净状态开始"
  if ! $CHECK_ONLY; then
    read -r -p "仍然继续? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || die "已取消"
  fi
fi

# --- 2. 版本号与 CHANGELOG 一致性检查 ----------------------------------------
VERSION=$(grep -E '^version:' pubspec.yaml | awk '{print $2}')
[[ -n "$VERSION" ]] || die "无法从 pubspec.yaml 读取 version"
grep -qF "## $VERSION" CHANGELOG.md \
  || die "CHANGELOG.md 没有提到当前版本 $VERSION,请先补充变更记录"
info "待发布版本: $VERSION"

# --- 3. 静态分析与测试 -------------------------------------------------------
info "flutter analyze ..."
flutter analyze
info "flutter test ..."
flutter test

# --- 4. 预检(dry-run) ---------------------------------------------------------
info "flutter pub publish --dry-run ..."
flutter pub publish --dry-run

if $CHECK_ONLY; then
  info "所有检查通过。执行 ./publish.sh 即可正式发布"
  exit 0
fi

# --- 5. 正式发布 -------------------------------------------------------------
# 注意:pub.dev 不允许重复发布相同版本号,若已发布过请先在 pubspec.yaml 升版本。
read -r -p "确认将 $VERSION 发布到 pub.dev? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || die "已取消"
info "正在发布(首次会提示用 Google 账号登录 pub.dev) ..."
flutter pub publish

# --- 6. 可选:打 git tag 并推送 ----------------------------------------------
if git tag | grep -qF "v$VERSION"; then
  warn "tag v$VERSION 已存在,跳过"
else
  read -r -p "创建并推送 git tag v$VERSION? [y/N] " ans
  if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
    git tag "v$VERSION"
    git push origin "v$VERSION" \
      || warn "tag 推送失败,请手动执行: git push origin v$VERSION"
  fi
fi

info "发布完成: fl_state_lifecycle $VERSION"
