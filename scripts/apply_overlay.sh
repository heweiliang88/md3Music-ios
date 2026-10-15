#!/usr/bin/env bash
# =============================================================================
# md3Music iOS 移植：把移植层叠加到上游源码上
#
#   用法: apply_overlay.sh <app_dir> <port_dir>
#
# 上游源码由 CI 在构建时从 GitHub 拉取（服务端网络，比本地快得多），
# 本仓库只承载"移植层"：源码改造脚本 + iOS 工程补丁 + CI 流水线。
# 这样既能保证上游可随时升级，又不用把 270MB 的上游仓库复制一份。
# =============================================================================
set -euo pipefail

APP_DIR="${1:?用法: apply_overlay.sh <app_dir> <port_dir>}"
PORT_DIR="${2:?用法: apply_overlay.sh <app_dir> <port_dir>}"
APP_DIR="$(cd "$APP_DIR" && pwd)"
PORT_DIR="$(cd "$PORT_DIR" && pwd)"

log() { printf '[overlay] %s\n' "$*"; }

[[ -f "$APP_DIR/pubspec.yaml" ]] || { log "不是有效的 md3Music 目录: $APP_DIR"; exit 1; }

# 1. 源码级改造（Cargo.toml + Dart FFI iOS 分支）
log "应用源码改造…"
python3 "$PORT_DIR/scripts/patch_sources.py" "$APP_DIR"

# 2. 生成 iOS 平台工程并打补丁
log "准备 iOS 平台工程…"
bash "$PORT_DIR/scripts/ios_prepare.sh" "$APP_DIR" "$PORT_DIR"

# 3. 记录移植版本，便于产物溯源
{
  echo "# 由 md3Music-ios 移植层生成"
  echo "port_overlay=md3music-ios"
  echo "generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "upstream_commit=$(cd "$APP_DIR" && git rev-parse HEAD 2>/dev/null || echo unknown)"
} > "$APP_DIR/.ios-port-info"

log "完成：$APP_DIR"
