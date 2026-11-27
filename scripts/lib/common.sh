#!/usr/bin/env bash
# 提供仓库级验证与发版打包脚本共用的日志输出、Python 探测及明文凭据安全扫描函数库。
#
# @author Ateng
# @since 2026-11-27

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

log_pass() {
  printf '[PASS] %s\n' "$*"
}

log_skip() {
  printf '[SKIP] %s\n' "$*"
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

is_true() {
  [[ "${1:-}" == "true" || "${1:-}" == "1" ]]
}

detect_python() {
  local required_module="${1:-sys}"
  local cand=""
  for cand in python3 python; do
    if command -v "${cand}" >/dev/null 2>&1 && "${cand}" -c "import ${required_module}" >/dev/null 2>&1; then
      printf '%s\n' "${cand}"
      return 0
    fi
  done
  return 1
}

# 从标准输入读取以 NUL 分隔的文件路径流，执行仓库唯一权威的明文私钥与第三方令牌扫描
scan_secrets_null_stream() {
  local pk_begin="-----BEGIN "
  local pk_end="PRIVATE KEY-----"
  local pk_regex="${pk_begin}(RSA |EC |DSA |OPENSSH |PGP )?${pk_end}"
  local token_regex='(ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|xox[baprs]-[0-9A-Za-z-]{10,})'
  local tmp_list=""
  local hits=""
  local has_hit=0

  tmp_list="$(mktemp)"
  cat > "${tmp_list}"

  if [[ -s "${tmp_list}" ]]; then
    hits="$(xargs -0 grep -HnE -e "${pk_regex}" < "${tmp_list}" || true)"
    if [[ -n "${hits}" ]]; then
      printf '%s\n' "${hits}" | sed 's/^/[SECRET:PRIVATE_KEY] /'
      has_hit=1
    fi

    hits="$(xargs -0 grep -HnE -e "${token_regex}" < "${tmp_list}" || true)"
    if [[ -n "${hits}" ]]; then
      printf '%s\n' "${hits}" | sed 's/^/[SECRET:TOKEN] /'
      has_hit=1
    fi
  fi

  rm -f "${tmp_list}"
  return "${has_hit}"
}

# 扫描换行分隔的文件清单，命中疑似凭据时输出详情并返回非零状态
scan_secrets_in_list_file() {
  local list_file="$1"
  [[ -s "${list_file}" ]] || return 0
  tr '\n' '\0' < "${list_file}" | scan_secrets_null_stream
}

# 递归扫描指定目录下全部普通文件，命中疑似凭据时输出详情并返回非零状态
scan_secrets_in_dir() {
  local target_dir="$1"
  [[ -d "${target_dir}" ]] || return 0
  target_dir="$(cd "${target_dir}" && pwd)"
  find "${target_dir}" -type f -print0 | scan_secrets_null_stream
}

# 校验目录内不含非示例真实 .env 文件且无明文私钥或第三方令牌
verify_dir_clean_and_safe() {
  local target_dir="$1"
  local label="$2"
  local env_hits=""
  local secret_hits=""

  if [[ ! -d "${target_dir}" ]]; then
    log_error "${label} 目标目录不存在：${target_dir}"
    return 1
  fi
  target_dir="$(cd "${target_dir}" && pwd)"

  env_hits="$(find "${target_dir}" -type f \( -name '.env' -o -name '.env.*' -o -name '*.env' -o -name '*.env.*' \) ! -name '*.env.example' ! -name '.env.example' || true)"
  if [[ -n "${env_hits}" ]]; then
    log_error "${label} 检测到禁止打包的真实环境配置文件：${env_hits}"
    return 1
  fi

  if ! secret_hits="$(scan_secrets_in_dir "${target_dir}")"; then
    log_error "${label} 检测到疑似明文私钥或第三方令牌："
    printf '%s\n' "${secret_hits}" >&2
    return 1
  fi
}
