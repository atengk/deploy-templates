#!/usr/bin/env bash
# 执行 Vue 3 生产级宿主机静态产物原子发布、运行时配置生成与系统 Nginx 平滑重载。
#
# @author Ateng
# @since 2026-11-27

set -euo pipefail

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

# 与 Docker 载体保持同一套 JS 字符级转义契约，安全生成运行时 config.js
generate_runtime_config() {
  local target_file="$1"
  local tmp_file="${target_file}.tmp.$$"

  LC_ALL=C awk '
  function trim(s) {
    gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", s)
    return s
  }
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
      v = trim(ENVIRON[k])
      if (v != "") {
        count++
        entries[count] = sprintf("  %s: \"%s\"", k, escape_js(v))
      }
    }
    print "// 由宿主机部署脚本在发布阶段动态生成，禁止浏览器缓存。"
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

ENV_FILE="${ENV_FILE:-/etc/vue3-pnpm/app.env}"
load_env_file "$ENV_FILE"

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/vue3-pnpm}"
NGINX_TEST_CMD="${NGINX_TEST_CMD:-nginx -t}"
NGINX_RELOAD_CMD="${NGINX_RELOAD_CMD:-systemctl reload nginx}"
SKIP_NGINX_RELOAD="${SKIP_NGINX_RELOAD:-false}"
ALLOW_OVERWRITE="${ALLOW_OVERWRITE:-false}"

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
if [ ! -f "${ARG_SOURCE}/index.html" ]; then
  log_error "静态产物目录缺少 index.html: ${ARG_SOURCE}"
  exit 1
fi

# 若环境变量与 ENV_FILE 未显式指定非空 APP_VERSION，则自动注入当前发布版本号（全空白视作未设置）
app_version_trimmed="${APP_VERSION:-}"
app_version_trimmed="${app_version_trimmed#"${app_version_trimmed%%[![:space:]]*}"}"
app_version_trimmed="${app_version_trimmed%"${app_version_trimmed##*[![:space:]]}"}"
if [ -n "$app_version_trimmed" ]; then
  export APP_VERSION="$app_version_trimmed"
else
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
    log_error "版本目录已存在: ${RELEASE_DIR}（如需覆写请传入 --force 或设置 ALLOW_OVERWRITE=true）"
    exit 1
  fi
fi

cleanup_staging() {
  rm -rf "$STAGING_DIR"
}
trap cleanup_staging EXIT

# 1. 复制静态产物至暂存目录并在发布前安全生成运行时 config.js
mkdir -p "$STAGING_DIR"
cp -a "${ARG_SOURCE}/." "${STAGING_DIR}/"
[ -f "${STAGING_DIR}/index.html" ] || {
  log_error "暂存目录校验失败，缺少 index.html"
  exit 1
}
generate_runtime_config "${STAGING_DIR}/config.js"

# 2. 若需覆盖已有版本目录先移除旧目录，再原子落盘新版本目录
if [ -e "$RELEASE_DIR" ]; then
  rm -rf "$RELEASE_DIR"
fi
mv "$STAGING_DIR" "$RELEASE_DIR"
trap - EXIT

# 3. 切换软链接前先校验 Nginx 配置，防止失败时污染当前激活版本
if ! is_truthy "$SKIP_NGINX_RELOAD"; then
  log_info "执行 Nginx 配置检查: ${NGINX_TEST_CMD}"
  bash -c "$NGINX_TEST_CMD"
fi

# 4. 记录切换前激活版本供一键回滚使用，随后原子切换 current 软链接
prev_version=""
if [ -L "$CURRENT_LINK" ]; then
  prev_target="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
  if [ -n "$prev_target" ] && [ -d "$prev_target" ]; then
    prev_version="$(basename "$prev_target")"
  fi
fi

atomic_switch_symlink "$RELEASE_DIR" "$CURRENT_LINK"

if [ -n "$prev_version" ] && [ "$prev_version" != "$ARG_VERSION" ] && [ -d "${RELEASES_DIR}/${prev_version}" ]; then
  printf '%s\n' "$prev_version" > "${PREVIOUS_FILE}.tmp.$$"
  mv -f "${PREVIOUS_FILE}.tmp.$$" "$PREVIOUS_FILE"
  atomic_switch_symlink "${RELEASES_DIR}/${prev_version}" "$PREVIOUS_LINK"
fi

log_info "已发布版本 ${ARG_VERSION} -> ${CURRENT_LINK}（已生成运行时 config.js）"

# 5. 平滑重载系统 Nginx 服务
if ! is_truthy "$SKIP_NGINX_RELOAD"; then
  log_info "执行 Nginx 平滑重载: ${NGINX_RELOAD_CMD}"
  bash -c "$NGINX_RELOAD_CMD"
else
  log_info "已按 SKIP_NGINX_RELOAD=${SKIP_NGINX_RELOAD} 跳过 Nginx 检查与重载"
fi
