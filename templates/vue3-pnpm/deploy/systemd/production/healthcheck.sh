#!/usr/bin/env bash
# 探测 Vue 3 生产级宿主机 Nginx 站点健康检查端点与可选运行时配置端点。
#
# @author Ateng
# @since 2026-11-27

set -euo pipefail

usage() {
  cat <<'EOF'
用法：
  healthcheck.sh

环境变量覆盖：
  ENV_FILE             环境配置文件路径（默认：/etc/vue3-pnpm/app.env）
  NGINX_PORT           站点监听端口（默认：80）
  HEALTHCHECK_URL      健康检查完整 URL（默认：http://127.0.0.1:${NGINX_PORT}/healthz）
  CURL_CMD             curl 可执行命令或桩路径（默认：curl）
  HEALTHCHECK_TIMEOUT  单次请求超时秒数（默认：5）
  HEALTHCHECK_RETRIES  最大重试次数（默认：3）
  HEALTHCHECK_INTERVAL 重试间隔秒数（默认：1）
  EXPECTED_BODY        期望响应中包含的文本（默认：ok，设为空则仅校验 HTTP 2xx）
  CHECK_CONFIG_URL     可选运行时 config.js 校验地址（默认为空，不探测）
EOF
}

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
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

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

ENV_FILE="${ENV_FILE:-/etc/vue3-pnpm/app.env}"
load_env_file "$ENV_FILE"

NGINX_PORT="${NGINX_PORT:-80}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-http://127.0.0.1:${NGINX_PORT}/healthz}"
CURL_CMD="${CURL_CMD:-curl}"
HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-5}"
HEALTHCHECK_RETRIES="${HEALTHCHECK_RETRIES:-3}"
HEALTHCHECK_INTERVAL="${HEALTHCHECK_INTERVAL:-1}"
EXPECTED_BODY="${EXPECTED_BODY-ok}"
CHECK_CONFIG_URL="${CHECK_CONFIG_URL:-}"

[[ "$HEALTHCHECK_RETRIES" =~ ^[1-9][0-9]*$ ]] || {
  log_error "HEALTHCHECK_RETRIES 必须为正整数: ${HEALTHCHECK_RETRIES}"
  exit 1
}

attempt=1
health_ok="false"
while [ "$attempt" -le "$HEALTHCHECK_RETRIES" ]; do
  if body="$("$CURL_CMD" -fsS --max-time "$HEALTHCHECK_TIMEOUT" "$HEALTHCHECK_URL" 2>/dev/null)"; then
    if [ -z "$EXPECTED_BODY" ] || [[ "$body" == *"$EXPECTED_BODY"* ]]; then
      health_ok="true"
      break
    fi
    log_error "第 ${attempt}/${HEALTHCHECK_RETRIES} 次健康检查响应异常: ${body}"
  else
    log_error "第 ${attempt}/${HEALTHCHECK_RETRIES} 次健康检查请求失败: ${HEALTHCHECK_URL}"
  fi

  if [ "$attempt" -lt "$HEALTHCHECK_RETRIES" ]; then
    sleep "$HEALTHCHECK_INTERVAL"
  fi
  attempt=$((attempt + 1))
done

if [ "$health_ok" != "true" ]; then
  log_error "健康检查最终失败（已重试 ${HEALTHCHECK_RETRIES} 次）: ${HEALTHCHECK_URL}"
  exit 1
fi

if [ -n "$CHECK_CONFIG_URL" ]; then
  if ! cfg_body="$("$CURL_CMD" -fsS --max-time "$HEALTHCHECK_TIMEOUT" "$CHECK_CONFIG_URL" 2>/dev/null)"; then
    log_error "运行时配置端点探测失败: ${CHECK_CONFIG_URL}"
    exit 1
  fi
  if [[ "$cfg_body" != *"__APP_CONFIG__"* ]]; then
    log_error "运行时配置端点响应不包含 __APP_CONFIG__: ${CHECK_CONFIG_URL}"
    exit 1
  fi
  log_info "健康检查与运行时配置端点探测均通过（${HEALTHCHECK_URL}, ${CHECK_CONFIG_URL}）"
else
  log_info "健康检查通过（${HEALTHCHECK_URL}）"
fi
