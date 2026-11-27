#!/usr/bin/env bash
# 执行 Vue 3 企业加固级宿主机静态产物不可变发布、权限收敛、运行时配置生成、健康验证与失败自动回滚。
#
# @author Ateng
# @since 2026-11-27

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
用法：
  deploy.sh [--version <版本号>] [--source <静态产物目录>] [--force]
  deploy.sh <版本号> [静态产物目录]

环境变量覆盖：
  DEPLOY_ROOT       部署根目录（默认：/opt/vue3-pnpm）
  ENV_FILE          环境配置文件路径（默认：/etc/vue3-pnpm/app.env）
  SOURCE_DIR        静态产物目录（默认：./dist）
  RELEASE_VERSION   发布版本号（也可通过参数传入）
  NGINX_TEST_CMD    Nginx 配置检查命令（默认：nginx -t）
  NGINX_RELOAD_CMD  Nginx 平滑重载命令（默认：systemctl reload nginx）
  SKIP_NGINX_RELOAD 设为 true/1 时跳过 Nginx 校验与重载（默认：false）
  ALLOW_OVERWRITE   设为 true/1 时允许覆盖已存在的同版本目录（默认：false）
  AUTO_HEALTHCHECK  设为 true/1 时重载后自动执行健康检查，失败自动回滚（默认：false）
  KEEP_RELEASES     保留最近版本数量，设为 0 则不自动清理（默认：5）
  DEPLOY_DIR_MODE   版本目录权限模式（默认：0755）
  DEPLOY_FILE_MODE  静态文件权限模式（默认：0644）
  DEPLOY_OWNER      可选目录属主与属组（如 root:nginx）
  STRICT_ENV_PERMS  设为 true/1 时严格校验 ENV_FILE 不得对组外其他人开放读/写权限（默认：false）
EOF
}

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
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

append_audit_log() {
  local action="$1"
  local version="$2"
  local status="$3"
  local audit_file="${DEPLOY_ROOT}/deploy-history.log"
  local ts
  local operator
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || printf 'unknown-time')"
  operator="${SUDO_USER:-${USER:-unknown}}"
  printf '%s | %s | %s | %s | %s\n' "$ts" "$action" "$version" "$operator" "$status" >> "$audit_file"
}

check_env_file_safety() {
  local file_path="$1"
  [ -f "$file_path" ] || return 0

  local mode
  mode="$(stat -c '%a' "$file_path" 2>/dev/null || stat -f '%Lp' "$file_path" 2>/dev/null || true)"
  [ -n "$mode" ] || return 0

  local other_digit
  other_digit="${mode: -1}"
  if [ $((other_digit & 2)) -ne 0 ]; then
    log_error "安全策略拒绝：环境配置文件对任意用户可写 (${mode}): ${file_path}"
    return 1
  fi
  if is_truthy "${STRICT_ENV_PERMS:-false}" && [ "$other_digit" -ne 0 ]; then
    log_error "严格权限策略拒绝：环境配置文件对 other 开放权限 (${mode}): ${file_path}"
    return 1
  fi
}

# 安全解析 KEY=VALUE 环境文件：仅注入当前进程尚未设置的变量，支持值内空格且不执行任意 Shell 代码
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
  [ -n "$ver" ] || { log_error "发布版本号不能为空"; return 1; }
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

generate_runtime_config() {
  local target_file="$1"
  local tmp_file="${target_file}.tmp.$$"

  LC_ALL=C awk '
  function escape_js(s,    i, n, c, out) {
    out = ""
    n = length(s)
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (c == "\\")      out = out "\\\\"
      else if (c == "\"") out = out "\\\""
      else if (c == "\n") out = out "\\n"
      else if (c == "\r") out = out "\\r"
      else if (c == "\t") out = out "\\t"
      else if (c == "\b") out = out "\\b"
      else if (c == "\f") out = out "\\f"
      else if (c == "<")  out = out "\\u003c"
      else if (c == ">")  out = out "\\u003e"
      else if (c == "&")  out = out "\\u0026"
      else                out = out c
    }
    return out
  }
  BEGIN {
    split("APP_TITLE APP_VERSION APP_ENV APP_API_BASE_URL", keys, " ")
    count = 0
    for (i = 1; i <= 4; i++) {
      k = keys[i]
      v = ENVIRON[k]
      if (v != "") {
        count++
        entries[count] = sprintf("  %s: \"%s\"", k, escape_js(v))
      }
    }
    print "// 由宿主机企业加固级部署脚本在发布阶段动态生成，禁止浏览器缓存。"
    if (count == 0) {
      print "window.__APP_CONFIG__ = Object.freeze({});"
    } else {
      print "window.__APP_CONFIG__ = Object.freeze({"
      for (i = 1; i <= count; i++) {
        if (i < count) printf "%s,\n", entries[i]
        else printf "%s\n", entries[i]
      }
      print "});"
    }
  }
  ' > "$tmp_file"

  mv -f "$tmp_file" "$target_file"
}

prune_old_releases() {
  local releases_dir="$1"
  local keep_count="$2"
  local protected_a="$3"
  local protected_b="$4"

  [[ "$keep_count" =~ ^[0-9]+$ ]] || return 0
  [ "$keep_count" -gt 0 ] || return 0

  local dir_name
  local idx=0
  while IFS= read -r dir_name; do
    [ -n "$dir_name" ] || continue
    [[ "$dir_name" == .* ]] && continue
    idx=$((idx + 1))
    if [ "$idx" -le "$keep_count" ]; then
      continue
    fi
    if [ "$dir_name" = "$protected_a" ] || [ "$dir_name" = "$protected_b" ]; then
      continue
    fi
    chmod -R u+rwX "${releases_dir}/${dir_name}" 2>/dev/null || true
    rm -rf "${releases_dir:?}/${dir_name}"
    log_info "已按保留策略清理历史版本: ${dir_name}"
  done < <(ls -1t "$releases_dir" 2>/dev/null || true)
}

ENV_FILE="${ENV_FILE:-/etc/vue3-pnpm/app.env}"
check_env_file_safety "$ENV_FILE"
load_env_file "$ENV_FILE"

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/vue3-pnpm}"
NGINX_TEST_CMD="${NGINX_TEST_CMD:-nginx -t}"
NGINX_RELOAD_CMD="${NGINX_RELOAD_CMD:-systemctl reload nginx}"
SKIP_NGINX_RELOAD="${SKIP_NGINX_RELOAD:-false}"
ALLOW_OVERWRITE="${ALLOW_OVERWRITE:-false}"
AUTO_HEALTHCHECK="${AUTO_HEALTHCHECK:-false}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
DEPLOY_DIR_MODE="${DEPLOY_DIR_MODE:-0755}"
DEPLOY_FILE_MODE="${DEPLOY_FILE_MODE:-0644}"
DEPLOY_OWNER="${DEPLOY_OWNER:-}"

ARG_VERSION="${RELEASE_VERSION:-}"
ARG_SOURCE="${SOURCE_DIR:-${DIST_DIR:-}}"

positional=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -v|--version)
      [ "$#" -ge 2 ] || { log_error "--version 缺少参数值"; exit 1; }
      ARG_VERSION="$2"
      shift 2
      ;;
    -s|--source)
      [ "$#" -ge 2 ] || { log_error "--source 缺少参数值"; exit 1; }
      ARG_SOURCE="$2"
      shift 2
      ;;
    --force)
      ALLOW_OVERWRITE="true"
      shift
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

if [ "${#positional[@]}" -ge 1 ] && [ -z "$ARG_VERSION" ]; then
  ARG_VERSION="${positional[0]}"
fi
if [ "${#positional[@]}" -ge 2 ] && [ -z "$ARG_SOURCE" ]; then
  ARG_SOURCE="${positional[1]}"
fi
if [ "${#positional[@]}" -gt 2 ]; then
  log_error "位置参数过多，请检查命令行参数"
  usage >&2
  exit 1
fi

ARG_SOURCE="${ARG_SOURCE:-./dist}"

validate_version "$ARG_VERSION"

if [ ! -d "$ARG_SOURCE" ]; then
  log_error "静态产物目录不存在: ${ARG_SOURCE}"
  exit 1
fi
if [ ! -f "${ARG_SOURCE}/index.html" ] || [ ! -s "${ARG_SOURCE}/index.html" ]; then
  log_error "静态产物目录缺少非空 index.html: ${ARG_SOURCE}"
  exit 1
fi

if [ -z "${APP_VERSION:-}" ]; then
  export APP_VERSION="$ARG_VERSION"
fi
export APP_TITLE="${APP_TITLE:-}"
export APP_ENV="${APP_ENV:-}"
export APP_API_BASE_URL="${APP_API_BASE_URL:-}"

RELEASES_DIR="${DEPLOY_ROOT}/releases"
RELEASE_DIR="${RELEASES_DIR}/${ARG_VERSION}"
CURRENT_LINK="${DEPLOY_ROOT}/current"
PREVIOUS_LINK="${DEPLOY_ROOT}/previous"
PREVIOUS_FILE="${DEPLOY_ROOT}/.previous_version"
STAGING_DIR="${RELEASES_DIR}/.staging-${ARG_VERSION}-$$"

mkdir -p "$RELEASES_DIR"

if [ -e "$RELEASE_DIR" ]; then
  if ! is_truthy "$ALLOW_OVERWRITE"; then
    log_error "不可变版本保护：目录已存在 ${RELEASE_DIR}（禁止静默覆盖在途版本，如需强制请传 --force）"
    exit 1
  fi
fi

cleanup_staging() {
  if [ -d "$STAGING_DIR" ]; then
    chmod -R u+rwX "$STAGING_DIR" 2>/dev/null || true
    rm -rf "$STAGING_DIR"
  fi
}
trap cleanup_staging EXIT

# 1. 复制静态产物至暂存目录、安全生成 config.js 并收敛只读权限
mkdir -p "$STAGING_DIR"
cp -a "${ARG_SOURCE}/." "${STAGING_DIR}/"
[ -s "${STAGING_DIR}/index.html" ] || {
  log_error "暂存目录校验失败，index.html 缺失或为空"
  exit 1
}
generate_runtime_config "${STAGING_DIR}/config.js"

find "$STAGING_DIR" -type d -exec chmod "$DEPLOY_DIR_MODE" {} +
find "$STAGING_DIR" -type f -exec chmod "$DEPLOY_FILE_MODE" {} +
if [ -n "$DEPLOY_OWNER" ]; then
  chown -R "$DEPLOY_OWNER" "$STAGING_DIR"
fi

# 2. 若需覆盖已有版本先解锁旧目录权限后清理，再原子落盘新版本目录
if [ -e "$RELEASE_DIR" ]; then
  chmod -R u+rwX "$RELEASE_DIR" 2>/dev/null || true
  rm -rf "$RELEASE_DIR"
fi
mv "$STAGING_DIR" "$RELEASE_DIR"
trap - EXIT

# 3. 切换软链接前先校验 Nginx 配置
if ! is_truthy "$SKIP_NGINX_RELOAD"; then
  log_info "执行 Nginx 配置检查: ${NGINX_TEST_CMD}"
  bash -c "$NGINX_TEST_CMD"
fi

# 4. 保存切换前状态并原子切换 current 软链接
prev_version=""
if [ -L "$CURRENT_LINK" ]; then
  prev_target="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
  if [ -n "$prev_target" ] && [ -d "$prev_target" ]; then
    prev_version="$(basename "$prev_target")"
  fi
fi

orig_previous_version=""
if [ -f "$PREVIOUS_FILE" ]; then
  orig_previous_version="$(tr -d '[:space:]\r' < "$PREVIOUS_FILE" || true)"
fi

atomic_switch_symlink "$RELEASE_DIR" "$CURRENT_LINK"

if [ -n "$prev_version" ] && [ "$prev_version" != "$ARG_VERSION" ] && [ -d "${RELEASES_DIR}/${prev_version}" ]; then
  printf '%s\n' "$prev_version" > "${PREVIOUS_FILE}.tmp.$$"
  mv -f "${PREVIOUS_FILE}.tmp.$$" "$PREVIOUS_FILE"
  atomic_switch_symlink "${RELEASES_DIR}/${prev_version}" "$PREVIOUS_LINK"
fi

# 5. 平滑重载系统 Nginx 服务
if ! is_truthy "$SKIP_NGINX_RELOAD"; then
  log_info "执行 Nginx 平滑重载: ${NGINX_RELOAD_CMD}"
  bash -c "$NGINX_RELOAD_CMD"
else
  log_info "已按 SKIP_NGINX_RELOAD=${SKIP_NGINX_RELOAD} 跳过 Nginx 检查与重载"
fi

# 6. 可选发布后健康校验闭环：探测失败时自动切回上一健康版本并再次重载 Nginx
if is_truthy "$AUTO_HEALTHCHECK"; then
  log_info "执行发布后自动健康校验..."
  if ! bash "${SCRIPT_DIR}/healthcheck.sh"; then
    log_error "发布后健康检查失败，触发自动回滚保护"
    if [ -n "$prev_version" ] && [ "$prev_version" != "$ARG_VERSION" ] && [ -d "${RELEASES_DIR}/${prev_version}" ]; then
      atomic_switch_symlink "${RELEASES_DIR}/${prev_version}" "$CURRENT_LINK"
      if [ -n "$orig_previous_version" ] && [ -d "${RELEASES_DIR}/${orig_previous_version}" ]; then
        printf '%s\n' "$orig_previous_version" > "${PREVIOUS_FILE}.tmp.$$"
        mv -f "${PREVIOUS_FILE}.tmp.$$" "$PREVIOUS_FILE"
        atomic_switch_symlink "${RELEASES_DIR}/${orig_previous_version}" "$PREVIOUS_LINK"
      else
        rm -f "$PREVIOUS_FILE" "$PREVIOUS_LINK"
      fi
      if ! is_truthy "$SKIP_NGINX_RELOAD"; then
        bash -c "$NGINX_RELOAD_CMD" || true
      fi
      append_audit_log "auto-rollback" "${ARG_VERSION}->${prev_version}" "healthcheck-failed"
      log_warn "已自动回滚至健康版本: ${prev_version}"
    else
      append_audit_log "deploy" "$ARG_VERSION" "healthcheck-failed"
    fi
    exit 1
  fi
fi

append_audit_log "deploy" "$ARG_VERSION" "success"
prune_old_releases "$RELEASES_DIR" "$KEEP_RELEASES" "$ARG_VERSION" "$prev_version"
log_info "已发布加固版本 ${ARG_VERSION} -> ${CURRENT_LINK}"
