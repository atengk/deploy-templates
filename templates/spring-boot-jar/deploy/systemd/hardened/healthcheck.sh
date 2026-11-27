#!/usr/bin/env bash
# 探测 Spring Boot 3 企业加固级服务就绪端点（hardened 默认独立管理端口 8081 /actuator/health/readiness）。
#
# @author Ateng
# @since 2026-11-27

set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/spring-boot-jar/app.env}"
CURL_CMD="${CURL_CMD:-curl}"
HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-3}"
HEALTHCHECK_RETRIES="${HEALTHCHECK_RETRIES:-1}"
HEALTHCHECK_INTERVAL="${HEALTHCHECK_INTERVAL:-2}"

usage() {
  cat <<'EOF'
用法：healthcheck.sh [target_url]

解析优先级：
  1. 命令行首个参数 target_url
  2. 环境变量 HEALTHCHECK_URL
  3. 环境变量或 ENV_FILE 中的 MANAGEMENT_SERVER_PORT 组装 http://127.0.0.1:<port>/actuator/health/readiness
  4. 默认地址 http://127.0.0.1:8081/actuator/health/readiness
EOF
}

read_env_value() {
  local key="$1"
  local file="$2"
  local line=""
  local val=""
  local result=""
  local found=0

  [[ -f "${file}" && -r "${file}" ]] || return 1

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ "${line}" =~ ^[[:space:]]*(export[[:space:]]+)?${key}=(.*)$ ]]; then
      val="${BASH_REMATCH[2]}"
      val="${val#"${val%%[![:space:]]*}"}"
      val="${val%"${val##*[![:space:]]}"}"
      if [[ "${val}" == \"*\" && "${val}" == *\" && ${#val} -ge 2 ]]; then
        val="${val:1:${#val}-2}"
      elif [[ "${val}" == \'*\' && "${val}" == *\' && ${#val} -ge 2 ]]; then
        val="${val:1:${#val}-2}"
      fi
      result="${val}"
      found=1
    fi
  done < "${file}"

  if [[ "${found}" -eq 1 ]]; then
    printf '%s\n' "${result}"
    return 0
  fi
  return 1
}

resolve_target_url() {
  local arg_url="${1:-}"
  local port=""
  local env_val=""

  if [[ -n "${arg_url}" ]]; then
    printf '%s\n' "${arg_url}"
    return 0
  fi

  if [[ -n "${HEALTHCHECK_URL:-}" ]]; then
    printf '%s\n' "${HEALTHCHECK_URL}"
    return 0
  fi

  if env_val="$(read_env_value "HEALTHCHECK_URL" "${ENV_FILE}")" && [[ -n "${env_val}" ]]; then
    printf '%s\n' "${env_val}"
    return 0
  fi

  if [[ -n "${MANAGEMENT_SERVER_PORT:-}" ]]; then
    port="${MANAGEMENT_SERVER_PORT}"
  elif env_val="$(read_env_value "MANAGEMENT_SERVER_PORT" "${ENV_FILE}")" && [[ -n "${env_val}" ]]; then
    port="${env_val}"
  else
    port="8081"
  fi

  printf 'http://127.0.0.1:%s/actuator/health/readiness\n' "${port}"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  if ! command -v "${CURL_CMD}" >/dev/null 2>&1; then
    printf '[ERROR] 未找到 curl 命令：%s\n' "${CURL_CMD}" >&2
    exit 1
  fi

  local target_url
  target_url="$(resolve_target_url "${1:-}")"

  local attempt=1
  while [[ "${attempt}" -le "${HEALTHCHECK_RETRIES}" ]]; do
    if "${CURL_CMD}" -fsS --connect-timeout "${HEALTHCHECK_TIMEOUT}" --max-time "${HEALTHCHECK_TIMEOUT}" "${target_url}" >/dev/null; then
      printf '[OK] 健康检查通过：%s\n' "${target_url}"
      exit 0
    fi
    if [[ "${attempt}" -lt "${HEALTHCHECK_RETRIES}" ]]; then
      sleep "${HEALTHCHECK_INTERVAL}"
    fi
    attempt=$((attempt + 1))
  done

  printf '[ERROR] 健康检查失败：%s\n' "${target_url}" >&2
  exit 1
}

main "$@"
