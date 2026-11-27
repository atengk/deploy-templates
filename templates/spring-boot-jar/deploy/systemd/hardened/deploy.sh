#!/usr/bin/env bash
# 部署 Spring Boot 3 可执行 Jar 至宿主机只读受控版本目录并原子切换 current 软链（hardened 企业加固级）。
#
# @author Ateng
# @since 2026-11-27

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/spring-boot-jar}"
ENV_FILE="${ENV_FILE:-/etc/spring-boot-jar/app.env}"
SERVICE_NAME="${SERVICE_NAME:-spring-boot-jar}"
APP_USER="${APP_USER:-springapp}"
APP_GROUP="${APP_GROUP:-springapp}"
SYSTEMCTL_CMD="${SYSTEMCTL_CMD:-systemctl}"
SKIP_SYSTEMCTL="${SKIP_SYSTEMCTL:-false}"
SKIP_CHOWN="${SKIP_CHOWN:-false}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
HEALTHCHECK_SCRIPT="${HEALTHCHECK_SCRIPT:-${SCRIPT_DIR}/healthcheck.sh}"

if [[ "${SKIP_SYSTEMCTL}" == "true" || "${SKIP_SYSTEMCTL}" == "1" ]]; then
  RUN_HEALTHCHECK="${RUN_HEALTHCHECK:-false}"
else
  RUN_HEALTHCHECK="${RUN_HEALTHCHECK:-true}"
fi

HEALTHCHECK_RETRIES="${HEALTHCHECK_RETRIES:-15}"
HEALTHCHECK_INTERVAL="${HEALTHCHECK_INTERVAL:-2}"

STAGING_DIR=""
TMP_LINK=""

usage() {
  cat <<'EOF'
用法：deploy.sh <jar_file> [version]

参数：
  jar_file    待发布的可执行 Jar 包路径
  version     可选发布版本号（默认使用当前时间戳，仅允许字母、数字、点、下划线与连字符）

环境变量覆盖：
  DEPLOY_ROOT       部署基目录（默认：/opt/spring-boot-jar）
  ENV_FILE          环境配置文件路径（默认：/etc/spring-boot-jar/app.env）
  SERVICE_NAME      systemd 服务名（默认：spring-boot-jar）
  APP_USER          运行用户（默认：springapp）
  APP_GROUP         运行用户组（默认：springapp）
  SYSTEMCTL_CMD     systemctl 命令路径（默认：systemctl）
  SKIP_SYSTEMCTL    设为 true 时跳过 systemctl 调用（用于无 systemd 隔离演练）
  SKIP_CHOWN        设为 true 时跳过文件属主调整（非 root 用户演练自动跳过）
  RUN_HEALTHCHECK   部署后是否执行健康检查（SKIP_SYSTEMCTL=true 时默认 false）
  KEEP_RELEASES     保留历史版本数（默认：5，设为 0 则不自动清理）
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
  if [[ -n "${STAGING_DIR}" && -d "${STAGING_DIR}" ]]; then
    rm -rf "${STAGING_DIR}"
  fi
  if [[ -n "${TMP_LINK}" && -L "${TMP_LINK}" ]]; then
    rm -f "${TMP_LINK}"
  fi
}
trap cleanup EXIT

is_true() {
  [[ "$1" == "true" || "$1" == "1" ]]
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

cleanup_old_releases() {
  local releases_dir="$1"
  local keep_count="$2"
  local current_version="$3"
  local history_file="${DEPLOY_ROOT}/.release-history"
  local ordered=()
  local kept=()
  local total=0
  local start_idx=0
  local i=0
  local ver=""
  local entry=""
  local dir_name=""
  local should_keep=0

  if [[ ! "${keep_count}" =~ ^[0-9]+$ || "${keep_count}" -eq 0 ]]; then
    return 0
  fi

  if [[ -f "${history_file}" ]]; then
    while IFS= read -r ver || [[ -n "${ver}" ]]; do
      ver="${ver%$'\r'}"
      if [[ -n "${ver}" && -d "${releases_dir}/${ver}" ]]; then
        ordered+=("${ver}")
      fi
    done < "${history_file}"
  fi

  total="${#ordered[@]}"
  if [[ "${total}" -gt "${keep_count}" ]]; then
    start_idx=$((total - keep_count))
  fi

  for ((i = start_idx; i < total; i++)); do
    kept+=("${ordered[i]}")
  done

  for entry in "${releases_dir}"/*; do
    [[ -d "${entry}" ]] || continue
    dir_name="$(basename "${entry}")"
    [[ "${dir_name}" == "${current_version}" ]] && continue

    should_keep=0
    for ver in "${kept[@]}"; do
      if [[ "${ver}" == "${dir_name}" ]]; then
        should_keep=1
        break
      fi
    done

    if [[ "${should_keep}" -eq 0 ]]; then
      rm -rf "${entry}"
      log_info "已清理旧版本目录：${entry}"
    fi
  done
}

apply_hardened_ownership() {
  local target_path="$1"

  if is_true "${SKIP_CHOWN}"; then
    return 0
  fi

  if [[ "$(id -u)" -ne 0 ]]; then
    log_info "当前非 root 身份运行，跳过 root:${APP_GROUP} 只读属主设置"
    return 0
  fi

  if ! id "${APP_USER}" >/dev/null 2>&1; then
    log_error "运行用户 ${APP_USER} 不存在，请先创建系统低权用户（如 useradd --system --no-create-home --shell /usr/sbin/nologin ${APP_USER}）"
    exit 1
  fi

  # 企业加固级采用 root 持有产物 + 应用属组只读权限（0750/0440），阻止运行期进程篡改应用包
  chown -R "root:${APP_GROUP}" "${target_path}"
}

check_env_file_permissions() {
  local env_perms=""

  if [[ ! -f "${ENV_FILE}" ]]; then
    log_warn "未检测到环境配置文件 ${ENV_FILE}，请参考 app.env.example 创建并设为 0640（root:${APP_GROUP}）"
    return 0
  fi

  if env_perms="$(stat -c '%a' "${ENV_FILE}" 2>/dev/null || true)" && [[ -n "${env_perms}" ]]; then
    if [[ "${env_perms}" != "640" && "${env_perms}" != "600" && "${env_perms}" != "400" && "${env_perms}" != "440" ]]; then
      log_warn "环境文件 ${ENV_FILE} 当前权限为 ${env_perms}，企业加固级必须收紧至 0640 或更严格权限"
    fi
  fi
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
    usage >&2
    exit 1
  fi

  local jar_file="$1"
  local version="${2:-$(date +%Y%m%d-%H%M%S)}"

  if [[ ! -f "${jar_file}" || ! -r "${jar_file}" || ! -s "${jar_file}" ]]; then
    log_error "Jar 文件不存在、不可读或为空：${jar_file}"
    exit 1
  fi

  if [[ ! "${version}" =~ ^[A-Za-z0-9._-]+$ || "${version}" == "." || "${version}" == ".." ]]; then
    log_error "版本号格式非法：${version}（仅允许字母、数字、点、下划线与连字符）"
    exit 1
  fi

  local releases_dir="${DEPLOY_ROOT}/releases"
  local current_link="${DEPLOY_ROOT}/current"
  local target_dir="${releases_dir}/${version}"

  mkdir -p "${releases_dir}"

  if [[ -e "${target_dir}" ]]; then
    log_error "目标版本目录已存在：${target_dir}，请使用新版本号发布"
    exit 1
  fi

  check_env_file_permissions

  # 1. 在同级暂存目录准备版本产物并收敛为只读权限（0440），再原子重命名入库
  STAGING_DIR="${releases_dir}/.${version}.staging.$$"
  mkdir -p "${STAGING_DIR}"
  cp -f "${jar_file}" "${STAGING_DIR}/app.jar"
  chmod 0750 "${STAGING_DIR}"
  chmod 0440 "${STAGING_DIR}/app.jar"
  apply_hardened_ownership "${STAGING_DIR}"
  mv "${STAGING_DIR}" "${target_dir}"
  STAGING_DIR=""

  # 2. 记录切换前版本，随后使用临时软链原子替换 current
  local prev_version=""
  if [[ -L "${current_link}" ]]; then
    prev_version="$(basename "$(readlink "${current_link}")")"
    if [[ -n "${prev_version}" && "${prev_version}" != "${version}" ]]; then
      printf '%s\n' "${prev_version}" > "${DEPLOY_ROOT}/.previous_version"
    fi
  fi

  TMP_LINK="${DEPLOY_ROOT}/.current.tmp.$$"
  ln -sfn "${target_dir}" "${TMP_LINK}"
  mv -Tf "${TMP_LINK}" "${current_link}"
  TMP_LINK=""

  record_release_history "${version}"
  log_info "已发布只读受控版本 ${version}，current 软链指向：${target_dir}"

  # 3. 触发 systemd 重载与服务重启（隔离演练模式可跳过）
  if ! is_true "${SKIP_SYSTEMCTL}"; then
    if ! command -v "${SYSTEMCTL_CMD}" >/dev/null 2>&1; then
      log_error "未找到 systemctl 命令：${SYSTEMCTL_CMD}"
      exit 1
    fi
    "${SYSTEMCTL_CMD}" daemon-reload
    "${SYSTEMCTL_CMD}" restart "${SERVICE_NAME}.service"
    log_info "已重启加固服务：${SERVICE_NAME}.service"
  else
    log_info "已设置 SKIP_SYSTEMCTL=${SKIP_SYSTEMCTL}，跳过 systemd 服务重启"
  fi

  # 4. 轮询健康检查验证服务就绪（默认探测回环管理端口 8081）
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
      log_warn "健康检查未就绪（第 ${attempt}/${HEALTHCHECK_RETRIES} 次），${HEALTHCHECK_INTERVAL} 秒后重试..."
      sleep "${HEALTHCHECK_INTERVAL}"
      attempt=$((attempt + 1))
    done

    if [[ "${ok}" -ne 1 ]]; then
      log_error "部署后健康检查超时失败，可执行 rollback.sh 一键回滚或使用 journalctl -u ${SERVICE_NAME} -n 100 排查日志"
      exit 1
    fi
  fi

  # 5. 按保留策略清理过期历史版本
  cleanup_old_releases "${releases_dir}" "${KEEP_RELEASES}" "${version}"
}

main "$@"
