#!/usr/bin/env bash
# 一键回滚 Spring Boot 3 宿主机 current 软链至上一版本或指定历史版本并重启服务（quickstart 快速级）。
#
# @author Ateng
# @since 2026-11-27

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/spring-boot-jar}"
ENV_FILE="${ENV_FILE:-/etc/spring-boot-jar/app.env}"
SERVICE_NAME="${SERVICE_NAME:-spring-boot-jar}"
SYSTEMCTL_CMD="${SYSTEMCTL_CMD:-systemctl}"
SKIP_SYSTEMCTL="${SKIP_SYSTEMCTL:-false}"
HEALTHCHECK_SCRIPT="${HEALTHCHECK_SCRIPT:-${SCRIPT_DIR}/healthcheck.sh}"

if [[ "${SKIP_SYSTEMCTL}" == "true" || "${SKIP_SYSTEMCTL}" == "1" ]]; then
  RUN_HEALTHCHECK="${RUN_HEALTHCHECK:-false}"
else
  RUN_HEALTHCHECK="${RUN_HEALTHCHECK:-true}"
fi

HEALTHCHECK_RETRIES="${HEALTHCHECK_RETRIES:-15}"
HEALTHCHECK_INTERVAL="${HEALTHCHECK_INTERVAL:-2}"

TMP_LINK=""

usage() {
  cat <<'EOF'
用法：rollback.sh [target_version]
      rollback.sh --list

参数：
  target_version  可选回滚目标版本号；未指定时自动回退至上一个有效发布版本
  --list, -l      列出可用历史版本与当前激活版本

环境变量覆盖：
  DEPLOY_ROOT       部署基目录（默认：/opt/spring-boot-jar）
  ENV_FILE          环境配置文件路径（默认：/etc/spring-boot-jar/app.env）
  SERVICE_NAME      systemd 服务名（默认：spring-boot-jar）
  SYSTEMCTL_CMD     systemctl 命令路径（默认：systemctl）
  SKIP_SYSTEMCTL    设为 true 时跳过 systemctl 调用（用于无 systemd 隔离演练）
  RUN_HEALTHCHECK   回滚后是否执行健康检查（SKIP_SYSTEMCTL=true 时默认 false）
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

cleanup() {
  if [[ -n "${TMP_LINK}" && -L "${TMP_LINK}" ]]; then
    rm -f "${TMP_LINK}"
  fi
}
trap cleanup EXIT

is_true() {
  [[ "$1" == "true" || "$1" == "1" ]]
}

get_current_version() {
  local current_link="${DEPLOY_ROOT}/current"
  if [[ -L "${current_link}" ]]; then
    basename "$(readlink "${current_link}")"
    return 0
  fi
  return 1
}

list_releases() {
  local releases_dir="${DEPLOY_ROOT}/releases"
  local current_ver=""
  local entry=""
  local dir_name=""

  current_ver="$(get_current_version 2>/dev/null || true)"
  if [[ ! -d "${releases_dir}" ]]; then
    log_warn "尚无发布目录：${releases_dir}"
    return 0
  fi

  for entry in "${releases_dir}"/*; do
    [[ -d "${entry}" ]] || continue
    dir_name="$(basename "${entry}")"
    if [[ "${dir_name}" == "${current_ver}" ]]; then
      printf '* %s (current)\n' "${dir_name}"
    else
      printf '  %s\n' "${dir_name}"
    fi
  done
}

record_release_history() {
  local version="$1"
  local history_file="${DEPLOY_ROOT}/.release-history"
  local existing=()
  local line=""
  local tmp_history=""

  if [[ -f "${history_file}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      line="${line%$'\r'}"
      [[ -n "${line}" && "${line}" != "${version}" ]] && existing+=("${line}")
    done < "${history_file}"
  fi

  tmp_history="${DEPLOY_ROOT}/.release-history.tmp.$$"
  : > "${tmp_history}"
  for line in "${existing[@]}"; do
    printf '%s\n' "${line}" >> "${tmp_history}"
  done
  printf '%s\n' "${version}" >> "${tmp_history}"
  mv -f "${tmp_history}" "${history_file}"
}

resolve_target_version() {
  local requested="$1"
  local current_ver="$2"
  local releases_dir="${DEPLOY_ROOT}/releases"
  local prev_file="${DEPLOY_ROOT}/.previous_version"
  local history_file="${DEPLOY_ROOT}/.release-history"
  local candidate=""
  local lines=()
  local idx=0
  local entry=""

  if [[ -n "${requested}" ]]; then
    if [[ ! "${requested}" =~ ^[A-Za-z0-9._-]+$ || "${requested}" == "." || "${requested}" == ".." ]]; then
      log_error "目标版本号格式非法：${requested}"
      return 1
    fi
    printf '%s\n' "${requested}"
    return 0
  fi

  # 1. 优先读取最近一次切换记录 .previous_version
  if [[ -f "${prev_file}" ]]; then
    IFS= read -r candidate < "${prev_file}" || true
    candidate="${candidate%$'\r'}"
    if [[ -n "${candidate}" && "${candidate}" != "${current_ver}" && -f "${releases_dir}/${candidate}/app.jar" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  fi

  # 2. 次选按发布历史栈倒序查找上一个有效版本
  if [[ -f "${history_file}" ]]; then
    while IFS= read -r candidate || [[ -n "${candidate}" ]]; do
      candidate="${candidate%$'\r'}"
      [[ -n "${candidate}" ]] && lines+=("${candidate}")
    done < "${history_file}"

    for ((idx = ${#lines[@]} - 1; idx >= 0; idx--)); do
      candidate="${lines[idx]}"
      if [[ "${candidate}" != "${current_ver}" && -f "${releases_dir}/${candidate}/app.jar" ]]; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    done
  fi

  # 3. 兜底扫描 releases 目录查找非当前的有效版本
  for entry in "${releases_dir}"/*; do
    [[ -d "${entry}" ]] || continue
    candidate="$(basename "${entry}")"
    if [[ "${candidate}" != "${current_ver}" && -f "${entry}/app.jar" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  if [[ "${1:-}" == "-l" || "${1:-}" == "--list" ]]; then
    list_releases
    exit 0
  fi

  if [[ "$#" -gt 1 ]]; then
    usage >&2
    exit 1
  fi

  local releases_dir="${DEPLOY_ROOT}/releases"
  local current_link="${DEPLOY_ROOT}/current"
  local current_ver=""

  if ! current_ver="$(get_current_version)"; then
    log_error "未检测到当前运行版本软链：${current_link}"
    exit 1
  fi

  local target_ver=""
  if ! target_ver="$(resolve_target_version "${1:-}" "${current_ver}")"; then
    log_error "未找到可回滚的历史版本（当前版本：${current_ver}）"
    exit 1
  fi

  if [[ "${target_ver}" == "${current_ver}" ]]; then
    log_error "目标版本与当前版本相同（${current_ver}），无需回滚"
    exit 1
  fi

  local target_dir="${releases_dir}/${target_ver}"
  if [[ ! -f "${target_dir}/app.jar" ]]; then
    log_error "目标版本产物不存在：${target_dir}/app.jar"
    exit 1
  fi

  # 1. 记录当前版本为上一状态并原子切换 current 软链
  printf '%s\n' "${current_ver}" > "${DEPLOY_ROOT}/.previous_version"
  TMP_LINK="${DEPLOY_ROOT}/.current.tmp.$$"
  ln -sfn "${target_dir}" "${TMP_LINK}"
  mv -Tf "${TMP_LINK}" "${current_link}"
  TMP_LINK=""

  record_release_history "${target_ver}"
  log_info "已完成软链回滚：${current_ver} -> ${target_ver}（${target_dir}）"

  # 2. 重启 systemd 服务（隔离演练模式可跳过）
  if ! is_true "${SKIP_SYSTEMCTL}"; then
    if ! command -v "${SYSTEMCTL_CMD}" >/dev/null 2>&1; then
      log_error "未找到 systemctl 命令：${SYSTEMCTL_CMD}"
      exit 1
    fi
    "${SYSTEMCTL_CMD}" restart "${SERVICE_NAME}.service"
    log_info "已重启服务：${SERVICE_NAME}.service"
  else
    log_info "已设置 SKIP_SYSTEMCTL=${SKIP_SYSTEMCTL}，跳过 systemd 服务重启"
  fi

  # 3. 轮询健康检查验证回滚后服务恢复就绪
  if is_true "${RUN_HEALTHCHECK}"; then
    if [[ ! -x "${HEALTHCHECK_SCRIPT}" && ! -f "${HEALTHCHECK_SCRIPT}" ]]; then
      log_error "未找到健康检查脚本：${HEALTHCHECK_SCRIPT}"
      exit 1
    fi
    local attempt=1
    local ok=0
    while [[ "${attempt}" -le "${HEALTHCHECK_RETRIES}" ]]; do
      if ENV_FILE="${ENV_FILE}" HEALTHCHECK_RETRIES=1 bash "${HEALTHCHECK_SCRIPT}"; then
        ok=1
        break
      fi
      log_warn "回滚后健康检查未就绪（第 ${attempt}/${HEALTHCHECK_RETRIES} 次），${HEALTHCHECK_INTERVAL} 秒后重试..."
      sleep "${HEALTHCHECK_INTERVAL}"
      attempt=$((attempt + 1))
    done

    if [[ "${ok}" -ne 1 ]]; then
      log_error "回滚后健康检查超时失败，可执行 journalctl -u ${SERVICE_NAME} -n 100 排查日志"
      exit 1
    fi
  fi
}

main "$@"
