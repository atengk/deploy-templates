#!/usr/bin/env bash
# 执行 Vue 3 生产级宿主机版本原子回滚并平滑重载系统 Nginx。
#
# @author Ateng
# @since 2026-11-27

set -euo pipefail

usage() {
  cat <<'EOF'
用法：
  rollback.sh [目标版本号]
  rollback.sh --version <目标版本号>

说明：
  未传入目标版本号时，自动回退至上一可用版本（读取 .previous_version 或 previous 软链接）。

环境变量覆盖：
  DEPLOY_ROOT       部署根目录（默认：/opt/vue3-pnpm）
  ENV_FILE          环境配置文件路径（默认：/etc/vue3-pnpm/app.env）
  NGINX_TEST_CMD    Nginx 配置检查命令（默认：nginx -t）
  NGINX_RELOAD_CMD  Nginx 平滑重载命令（默认：systemctl reload nginx）
  SKIP_NGINX_RELOAD 设为 true/1 时跳过 Nginx 校验与重载（默认：false）
EOF
}

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

load_env_file() {
  local file_path="$1"
  [ -f "$file_path" ] || return 0

  local line key val first_char last_char
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue
    [[ "$line" == export[[:space:]]* ]] && line="${line#export}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ "$line" == *=* ]] || continue

    key="${line%%=*}"
    val="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"

    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    if [ "${#val}" -ge 2 ]; then
      first_char="${val:0:1}"
      last_char="${val: -1}"
      if { [ "$first_char" = '"' ] && [ "$last_char" = '"' ]; } || \
         { [ "$first_char" = "'" ] && [ "$last_char" = "'" ]; }; then
        val="${val:1:${#val}-2}"
      fi
    fi

    if [ -z "${!key+x}" ]; then
      export "${key}=${val}"
    fi
  done < "$file_path"
}

validate_version() {
  local ver="$1"
  [ -n "$ver" ] || { log_error "回滚目标版本号不能为空"; return 1; }
  [ "$ver" != "." ] && [ "$ver" != ".." ] || { log_error "非法版本号: ${ver}"; return 1; }
  [[ "$ver" =~ ^[A-Za-z0-9._+-]+$ ]] || {
    log_error "非法版本号 '${ver}'：仅允许字母、数字、点、下划线、加号与连字符"
    return 1
  }
}

atomic_switch_symlink() {
  local target_dir="$1"
  local link_path="$2"
  local tmp_link="${link_path}.tmp.$$"

  if [ -e "$link_path" ] && [ ! -L "$link_path" ]; then
    log_error "目标路径 ${link_path} 已存在且不是软链接，拒绝覆盖以防误删目录"
    return 1
  fi

  ln -sfn "$target_dir" "$tmp_link"
  if ! mv -Tf "$tmp_link" "$link_path" 2>/dev/null; then
    rm -f "$tmp_link"
    ln -sfn "$target_dir" "$link_path"
  fi
}

ENV_FILE="${ENV_FILE:-/etc/vue3-pnpm/app.env}"
load_env_file "$ENV_FILE"

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/vue3-pnpm}"
NGINX_TEST_CMD="${NGINX_TEST_CMD:-nginx -t}"
NGINX_RELOAD_CMD="${NGINX_RELOAD_CMD:-systemctl reload nginx}"
SKIP_NGINX_RELOAD="${SKIP_NGINX_RELOAD:-false}"

TARGET_VERSION=""
positional=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -v|--version)
      [ "$#" -ge 2 ] || { log_error "--version 缺少参数值"; exit 1; }
      TARGET_VERSION="$2"
      shift 2
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        positional+=("$1")
        shift
      done
      ;;
    -*)
      log_error "未知参数: $1"
      usage >&2
      exit 1
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

if [ "${#positional[@]}" -ge 1 ] && [ -z "$TARGET_VERSION" ]; then
  TARGET_VERSION="${positional[0]}"
fi
if [ "${#positional[@]}" -gt 1 ]; then
  log_error "位置参数过多，仅接受单个可选目标版本号"
  usage >&2
  exit 1
fi

RELEASES_DIR="${DEPLOY_ROOT}/releases"
CURRENT_LINK="${DEPLOY_ROOT}/current"
PREVIOUS_LINK="${DEPLOY_ROOT}/previous"
PREVIOUS_FILE="${DEPLOY_ROOT}/.previous_version"

current_version=""
if [ -L "$CURRENT_LINK" ]; then
  current_target="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
  if [ -n "$current_target" ]; then
    current_version="$(basename "$current_target")"
  fi
fi

# 1. 未显式传参时，依次从 .previous_version 与 previous 软链接解析上一可用版本
if [ -z "$TARGET_VERSION" ]; then
  if [ -f "$PREVIOUS_FILE" ]; then
    TARGET_VERSION="$(tr -d '[:space:]\r' < "$PREVIOUS_FILE")"
  elif [ -L "$PREVIOUS_LINK" ]; then
    prev_resolved="$(readlink -f "$PREVIOUS_LINK" 2>/dev/null || true)"
    [ -n "$prev_resolved" ] && TARGET_VERSION="$(basename "$prev_resolved")"
  fi
fi

[ -n "$TARGET_VERSION" ] || {
  log_error "未指定目标版本号且未找到可用的上一版本记录"
  exit 1
}

validate_version "$TARGET_VERSION"

TARGET_DIR="${RELEASES_DIR}/${TARGET_VERSION}"
if [ ! -d "$TARGET_DIR" ] || [ ! -f "${TARGET_DIR}/index.html" ]; then
  log_error "目标回滚版本无效或缺少 index.html: ${TARGET_DIR}"
  exit 1
fi

if [ -n "$current_version" ] && [ "$current_version" = "$TARGET_VERSION" ]; then
  log_info "当前已处于版本 ${TARGET_VERSION}，无需重复切换"
  exit 0
fi

# 2. 回滚切换前校验 Nginx 配置
if ! is_truthy "$SKIP_NGINX_RELOAD"; then
  log_info "执行 Nginx 配置检查: ${NGINX_TEST_CMD}"
  bash -c "$NGINX_TEST_CMD"
fi

# 3. 原子切换 current 软链接并反转回滚指针以支持二次切回
atomic_switch_symlink "$TARGET_DIR" "$CURRENT_LINK"

if [ -n "$current_version" ] && [ -d "${RELEASES_DIR}/${current_version}" ]; then
  printf '%s\n' "$current_version" > "${PREVIOUS_FILE}.tmp.$$"
  mv -f "${PREVIOUS_FILE}.tmp.$$" "$PREVIOUS_FILE"
  atomic_switch_symlink "${RELEASES_DIR}/${current_version}" "$PREVIOUS_LINK"
fi

log_info "已回滚至版本 ${TARGET_VERSION}（current -> ${TARGET_DIR}）"

# 4. 平滑重载系统 Nginx 服务
if ! is_truthy "$SKIP_NGINX_RELOAD"; then
  log_info "执行 Nginx 平滑重载: ${NGINX_RELOAD_CMD}"
  bash -c "$NGINX_RELOAD_CMD"
else
  log_info "已按 SKIP_NGINX_RELOAD=${SKIP_NGINX_RELOAD} 跳过 Nginx 检查与重载"
fi
