#!/usr/bin/env bash
# 在无 root、无 systemd 与无 nginx 的隔离临时目录中全链路黑盒演练两栈三级宿主机发布、升级、回滚与健康检查。
#
# @author Ateng
# @since 2026-11-27

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

TARGET_STACK="all"
WORK_TMP=""

usage() {
  cat <<'EOF'
用法：verify-host.sh [--stack spring-boot-jar|vue3-pnpm|all]

选项：
  --stack <栈名>    指定演练的技术栈（默认：all）
EOF
}

cleanup() {
  if [[ -n "${WORK_TMP}" && -d "${WORK_TMP}" ]]; then
    chmod -R u+rwX "${WORK_TMP}" 2>/dev/null || true
    rm -rf "${WORK_TMP}"
  fi
}
trap cleanup EXIT

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --stack)
      if [[ "$#" -lt 2 || -z "$2" ]]; then
        log_error "--stack 缺少参数值"
        exit 1
      fi
      TARGET_STACK="$2"
      shift 2
      ;;
    *)
      log_error "未知参数：$1"
      usage >&2
      exit 1
      ;;
  esac
done

case "${TARGET_STACK}" in
  spring-boot-jar|vue3-pnpm|all) ;;
  *)
    log_error "不支持的 --stack 参数：${TARGET_STACK}（仅允许 spring-boot-jar、vue3-pnpm 或 all）"
    exit 1
    ;;
esac

prepare_symlink_capability() {
  case "$(uname -s 2>/dev/null || printf 'unknown')" in
    MINGW*|MSYS*|CYGWIN*)
      export MSYS="${MSYS:-winsymlinks:nativestrict}"
      ;;
  esac

  local probe_dir="${WORK_TMP}/symlink-probe"
  mkdir -p "${probe_dir}/target"
  if ! ln -sfn "${probe_dir}/target" "${probe_dir}/link" 2>/dev/null || [[ ! -L "${probe_dir}/link" ]]; then
    log_error "当前环境不支持创建原生符号链接（Windows 下请开启开发者模式或配置 MSYS=winsymlinks:nativestrict）"
    exit 1
  fi
  rm -rf "${probe_dir}"
}

prepare_mock_tools() {
  local bin_dir="${WORK_TMP}/mock-bin"
  mkdir -p "${bin_dir}"

  cat > "${bin_dir}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_ACTION_LOG:-}" ]]; then
  printf 'systemctl %s\n' "$*" >> "${MOCK_ACTION_LOG}"
fi
EOF

  cat > "${bin_dir}/nginx-test" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_ACTION_LOG:-}" ]]; then
  printf 'nginx-test\n' >> "${MOCK_ACTION_LOG}"
fi
EOF

  cat > "${bin_dir}/nginx-reload" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_ACTION_LOG:-}" ]]; then
  printf 'nginx-reload\n' >> "${MOCK_ACTION_LOG}"
fi
EOF

  cat > "${bin_dir}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

hdr_file=""
url=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -D|--dump-header)
      hdr_file="$2"
      shift 2
      ;;
    --connect-timeout|--max-time|-m|-X|-o|-w)
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

if [[ -n "${MOCK_CURL_LOG:-}" ]]; then
  printf '%s\n' "${url}" >> "${MOCK_CURL_LOG}"
fi

mode="${MOCK_CURL_MODE:-ok}"
if [[ "${mode}" == "fail" ]]; then
  exit 22
fi

if [[ "${url}" == *"/config.js" ]]; then
  if [[ -n "${hdr_file}" ]]; then
    if [[ "${mode}" == "no-nostore" ]]; then
      printf 'HTTP/1.1 200 OK\r\nContent-Type: application/javascript\r\n\r\n' > "${hdr_file}"
    else
      printf 'HTTP/1.1 200 OK\r\nContent-Type: application/javascript\r\nCache-Control: no-store, no-cache, must-revalidate\r\n\r\n' > "${hdr_file}"
    fi
  fi
  if [[ -n "${MOCK_CONFIG_JS_FILE:-}" && -f "${MOCK_CONFIG_JS_FILE}" ]]; then
    cat "${MOCK_CONFIG_JS_FILE}"
  else
    printf 'window.__APP_CONFIG__ = Object.freeze({});\n'
  fi
  exit 0
fi

if [[ "${url}" == *"/healthz" ]]; then
  printf 'ok\n'
  exit 0
fi

if [[ "${url}" == *"/actuator/health"* ]]; then
  printf '{"status":"UP"}\n'
  exit 0
fi

printf 'ok\n'
EOF

  chmod +x "${bin_dir}/systemctl" "${bin_dir}/nginx-test" "${bin_dir}/nginx-reload" "${bin_dir}/curl"
}

assert_symlink_version() {
  local current_link="$1"
  local expected_version="$2"
  local actual=""

  if [[ ! -L "${current_link}" ]]; then
    log_error "current 不是有效符号链接：${current_link}"
    return 1
  fi
  actual="$(basename "$(readlink "${current_link}")")"
  if [[ "${actual}" != "${expected_version}" ]]; then
    log_error "软链版本断言失败：期望 ${expected_version}，实际 ${actual}（${current_link}）"
    return 1
  fi
}

assert_vue3_config_js() {
  local config_file="$1"
  local expected_version="$2"
  local expected_api_url="$3"
  local expected_title="$4"

  if [[ ! -f "${config_file}" ]]; then
    log_error "未生成运行时配置文件：${config_file}"
    return 1
  fi

  grep -Fq 'window.__APP_CONFIG__' "${config_file}"
  grep -Fq "${expected_api_url}" "${config_file}"
  grep -Fq "\"${expected_version}\"" "${config_file}"

  if command -v node >/dev/null 2>&1; then
    node --check "${config_file}"
    CONFIG_FILE="${config_file}" \
    EXPECTED_VERSION="${expected_version}" \
    EXPECTED_API_URL="${expected_api_url}" \
    EXPECTED_TITLE="${expected_title}" \
      node -e '
        const fs = require("fs");
        const vm = require("vm");
        const code = fs.readFileSync(process.env.CONFIG_FILE, "utf8");
        const sandbox = { window: {}, Object };
        vm.runInNewContext(code, sandbox);
        const cfg = sandbox.window.__APP_CONFIG__;
        if (!cfg || typeof cfg !== "object") throw new Error("missing __APP_CONFIG__");
        if (cfg.APP_VERSION !== process.env.EXPECTED_VERSION) {
          throw new Error("APP_VERSION mismatch: " + cfg.APP_VERSION);
        }
        if (cfg.APP_API_BASE_URL !== process.env.EXPECTED_API_URL) {
          throw new Error("APP_API_BASE_URL mismatch: " + cfg.APP_API_BASE_URL);
        }
        if (cfg.APP_TITLE !== process.env.EXPECTED_TITLE) {
          throw new Error("APP_TITLE mismatch: " + cfg.APP_TITLE);
        }
      '
  fi
}

verify_spring_boot_host_tier() {
  local tier="$1"
  local systemd_dir="${REPO_ROOT}/templates/spring-boot-jar/deploy/systemd/${tier}"
  local tier_work="${WORK_TMP}/sb-${tier}"
  local deploy_root="${tier_work}/opt/spring-boot-jar"
  local env_file="${tier_work}/etc/app.env"
  local artifacts_dir="${tier_work}/artifacts"
  local action_log="${tier_work}/actions.log"
  local curl_log="${tier_work}/curl.log"
  local bin_dir="${WORK_TMP}/mock-bin"

  mkdir -p "${tier_work}/etc" "${artifacts_dir}"

  local real_jar="${REPO_ROOT}/templates/spring-boot-jar/app/target/app.jar"
  local jar_v1="${artifacts_dir}/app-v1.0.0.jar"
  local jar_v2="${artifacts_dir}/app-v1.1.0.jar"
  local jar_v3="${artifacts_dir}/app-v1.2.0.jar"

  if [[ -f "${real_jar}" && -s "${real_jar}" ]]; then
    cp -f "${real_jar}" "${jar_v1}"
  else
    printf 'spring-boot-jar-artifact-v1.0.0\n' > "${jar_v1}"
  fi
  printf 'spring-boot-jar-artifact-v1.1.0\n' > "${jar_v2}"
  printf 'spring-boot-jar-artifact-v1.2.0\n' > "${jar_v3}"

  if [[ "${tier}" == "quickstart" ]]; then
    printf 'SERVER_PORT=18080\nAPP_ENV=%s\n' "${tier}" > "${env_file}"
  else
    printf 'SERVER_PORT=18080\nMANAGEMENT_SERVER_PORT=18081\nAPP_ENV=%s\n' "${tier}" > "${env_file}"
  fi
  chmod 0640 "${env_file}"

  export DEPLOY_ROOT="${deploy_root}"
  export ENV_FILE="${env_file}"
  export SYSTEMCTL_CMD="${bin_dir}/systemctl"
  export SKIP_SYSTEMCTL="false"
  export SKIP_CHOWN="true"
  export RUN_HEALTHCHECK="true"
  export CURL_CMD="${bin_dir}/curl"
  export HEALTHCHECK_RETRIES="1"
  export HEALTHCHECK_INTERVAL="1"
  export MOCK_ACTION_LOG="${action_log}"
  export MOCK_CURL_LOG="${curl_log}"
  export MOCK_CURL_MODE="ok"

  # 1. 首次发布 v1.0.0
  bash "${systemd_dir}/deploy.sh" "${jar_v1}" "v1.0.0" >/dev/null
  assert_symlink_version "${deploy_root}/current" "v1.0.0"
  cmp -s "${deploy_root}/current/app.jar" "${jar_v1}"
  grep -Fq 'systemctl daemon-reload' "${action_log}"
  grep -Fq 'systemctl restart spring-boot-jar.service' "${action_log}"

  if [[ "${tier}" == "quickstart" ]]; then
    grep -Fq 'http://127.0.0.1:18080/actuator/health' "${curl_log}"
  else
    grep -Fq 'http://127.0.0.1:18081/actuator/health/readiness' "${curl_log}"
  fi

  # 2. 二次升级 v1.1.0
  bash "${systemd_dir}/deploy.sh" "${jar_v2}" "v1.1.0" >/dev/null
  assert_symlink_version "${deploy_root}/current" "v1.1.0"
  cmp -s "${deploy_root}/current/app.jar" "${jar_v2}"

  # 3. 验证防重复覆盖同版本保护
  if bash "${systemd_dir}/deploy.sh" "${jar_v2}" "v1.1.0" >/dev/null 2>&1; then
    log_error "Spring Boot ${tier} 未阻断重复发布同版本 v1.1.0"
    return 1
  fi

  # 4. 健康检查脚本独立正反例实测
  bash "${systemd_dir}/healthcheck.sh" >/dev/null
  if MOCK_CURL_MODE="fail" bash "${systemd_dir}/healthcheck.sh" >/dev/null 2>&1; then
    log_error "Spring Boot ${tier} healthcheck.sh 在异常响应时未返回非零退出码"
    return 1
  fi

  # 5. 三级回滚全链路（自动回滚 + 指定版本回滚）
  local list_out=""
  list_out="$(bash "${systemd_dir}/rollback.sh" --list)"
  grep -Fq '* v1.1.0 (current)' <<< "${list_out}"
  grep -Fq 'v1.0.0' <<< "${list_out}"

  bash "${systemd_dir}/rollback.sh" >/dev/null
  assert_symlink_version "${deploy_root}/current" "v1.0.0"
  cmp -s "${deploy_root}/current/app.jar" "${jar_v1}"

  bash "${systemd_dir}/deploy.sh" "${jar_v3}" "v1.2.0" >/dev/null
  assert_symlink_version "${deploy_root}/current" "v1.2.0"

  bash "${systemd_dir}/rollback.sh" "v1.1.0" >/dev/null
  assert_symlink_version "${deploy_root}/current" "v1.1.0"
  cmp -s "${deploy_root}/current/app.jar" "${jar_v2}"

  log_pass "Spring Boot 3 宿主机全链路演练通过 [${tier}]"
}

verify_vue3_host_tier() {
  local tier="$1"
  local systemd_dir="${REPO_ROOT}/templates/vue3-pnpm/deploy/systemd/${tier}"
  local tier_work="${WORK_TMP}/vue-${tier}"
  local deploy_root="${tier_work}/opt/vue3-pnpm"
  local env_file="${tier_work}/etc/app.env"
  local dist_v1="${tier_work}/dist-v1"
  local dist_v2="${tier_work}/dist-v2"
  local dist_bad="${tier_work}/dist-bad"
  local action_log="${tier_work}/actions.log"
  local curl_log="${tier_work}/curl.log"
  local bin_dir="${WORK_TMP}/mock-bin"
  local title_v1='Vue3演练 "门户" & <v1>'
  local title_v2='Vue3演练 "门户" & <v2>'

  mkdir -p "${tier_work}/etc" "${dist_v1}/assets" "${dist_v2}/assets" "${dist_bad}/assets"

  cat > "${dist_v1}/index.html" <<'EOF'
<!doctype html><html lang="zh-CN"><head><script src="/config.js"></script></head><body><div id="app">v1.0.0</div></body></html>
EOF
  printf 'console.log("v1");\n' > "${dist_v1}/assets/app-v1.js"

  cat > "${dist_v2}/index.html" <<'EOF'
<!doctype html><html lang="zh-CN"><head><script src="/config.js"></script></head><body><div id="app">v1.1.0</div></body></html>
EOF
  printf 'console.log("v2");\n' > "${dist_v2}/assets/app-v2.js"

  cat > "${dist_bad}/index.html" <<'EOF'
<!doctype html><html lang="zh-CN"><head><script src="/config.js"></script></head><body><div id="app">v1.2.0-bad</div></body></html>
EOF

  cat > "${env_file}" <<EOF
NGINX_PORT=18088
APP_TITLE=${title_v1}
APP_ENV=staging
APP_API_BASE_URL=https://api-v1.example.com
EOF
  chmod 0640 "${env_file}"

  # 隔离环境参数覆盖：避免宿主机现有环境变量意外穿透覆盖 env_file 解析值
  unset APP_TITLE APP_VERSION APP_ENV APP_API_BASE_URL || true

  export DEPLOY_ROOT="${deploy_root}"
  export ENV_FILE="${env_file}"
  export NGINX_TEST_CMD="${bin_dir}/nginx-test"
  export NGINX_RELOAD_CMD="${bin_dir}/nginx-reload"
  export SKIP_NGINX_RELOAD="false"
  export ALLOW_OVERWRITE="false"
  export CURL_CMD="${bin_dir}/curl"
  export HEALTHCHECK_RETRIES="1"
  export HEALTHCHECK_INTERVAL="1"
  export MOCK_ACTION_LOG="${action_log}"
  export MOCK_CURL_LOG="${curl_log}"
  export MOCK_CURL_MODE="ok"

  # 1. 首次发布 v1.0.0
  bash "${systemd_dir}/deploy.sh" "v1.0.0" "${dist_v1}" >/dev/null
  assert_symlink_version "${deploy_root}/current" "v1.0.0"
  cmp -s "${deploy_root}/current/index.html" "${dist_v1}/index.html"
  grep -Fq 'nginx-test' "${action_log}"
  grep -Fq 'nginx-reload' "${action_log}"

  if [[ "${tier}" != "quickstart" ]]; then
    assert_vue3_config_js "${deploy_root}/current/config.js" "v1.0.0" "https://api-v1.example.com" "${title_v1}"
  fi

  # 2. 更新配置并二次升级 v1.1.0
  cat > "${env_file}" <<EOF
NGINX_PORT=18088
APP_TITLE=${title_v2}
APP_ENV=production
APP_API_BASE_URL=https://api-v2.example.com
EOF
  chmod 0640 "${env_file}"

  bash "${systemd_dir}/deploy.sh" "v1.1.0" "${dist_v2}" >/dev/null
  assert_symlink_version "${deploy_root}/current" "v1.1.0"
  cmp -s "${deploy_root}/current/index.html" "${dist_v2}/index.html"

  if [[ "${tier}" != "quickstart" ]]; then
    assert_vue3_config_js "${deploy_root}/current/config.js" "v1.1.0" "https://api-v2.example.com" "${title_v2}"
  fi
  assert_symlink_version "${deploy_root}/previous" "v1.0.0"

  # 3. 重复发布保护
  if bash "${systemd_dir}/deploy.sh" "v1.1.0" "${dist_v2}" >/dev/null 2>&1; then
    log_error "Vue 3 ${tier} 未阻断重复发布同版本 v1.1.0"
    return 1
  fi

  # 4. 健康检查正反例实测
  if [[ "${tier}" == "quickstart" ]]; then
    bash "${systemd_dir}/healthcheck.sh" >/dev/null
    grep -Fq 'http://127.0.0.1:18088/healthz' "${curl_log}"
  else
    MOCK_CONFIG_JS_FILE="${deploy_root}/current/config.js" \
    CHECK_CONFIG_URL="http://127.0.0.1:18088/config.js" \
      bash "${systemd_dir}/healthcheck.sh" >/dev/null
  fi

  if MOCK_CURL_MODE="fail" bash "${systemd_dir}/healthcheck.sh" >/dev/null 2>&1; then
    log_error "Vue 3 ${tier} healthcheck.sh 在失败状态下未返回非零退出码"
    return 1
  fi

  # 5. 三级回滚链路与加固审计自动回滚实测
  bash "${systemd_dir}/rollback.sh" >/dev/null
  assert_symlink_version "${deploy_root}/current" "v1.0.0"
  cmp -s "${deploy_root}/current/index.html" "${dist_v1}/index.html"
  if [[ "${tier}" != "quickstart" ]]; then
    assert_vue3_config_js "${deploy_root}/current/config.js" "v1.0.0" "https://api-v1.example.com" "${title_v1}"
  fi

  bash "${systemd_dir}/rollback.sh" "v1.1.0" >/dev/null
  assert_symlink_version "${deploy_root}/current" "v1.1.0"
  cmp -s "${deploy_root}/current/index.html" "${dist_v2}/index.html"
  if [[ "${tier}" != "quickstart" ]]; then
    assert_vue3_config_js "${deploy_root}/current/config.js" "v1.1.0" "https://api-v2.example.com" "${title_v2}"
  fi

  if [[ "${tier}" == "hardened" ]]; then
    if MOCK_CURL_MODE="no-nostore" \
       MOCK_CONFIG_JS_FILE="${deploy_root}/current/config.js" \
       CHECK_CONFIG_URL="http://127.0.0.1:18088/config.js" \
       bash "${systemd_dir}/healthcheck.sh" >/dev/null 2>&1; then
      log_error "Vue 3 hardened healthcheck.sh 未拦截缺少 Cache-Control: no-store 的响应"
      return 1
    fi

    if AUTO_HEALTHCHECK="true" MOCK_CURL_MODE="fail" bash "${systemd_dir}/deploy.sh" "v1.2.0-bad" "${dist_bad}" >/dev/null 2>&1; then
      log_error "Vue 3 hardened AUTO_HEALTHCHECK 失败时应退出非零"
      return 1
    fi
    assert_symlink_version "${deploy_root}/current" "v1.1.0"
    grep -Fq 'auto-rollback | v1.2.0-bad->v1.1.0' "${deploy_root}/deploy-history.log"
  fi

  log_pass "Vue 3 宿主机全链路演练通过 [${tier}]"
}

main() {
  WORK_TMP="$(mktemp -d)"
  prepare_symlink_capability
  prepare_mock_tools

  local tier=""
  if [[ "${TARGET_STACK}" == "spring-boot-jar" || "${TARGET_STACK}" == "all" ]]; then
    for tier in quickstart production hardened; do
      verify_spring_boot_host_tier "${tier}"
    done
  fi

  if [[ "${TARGET_STACK}" == "vue3-pnpm" || "${TARGET_STACK}" == "all" ]]; then
    for tier in quickstart production hardened; do
      verify_vue3_host_tier "${tier}"
    done
  fi

  log_info "宿主机全链路隔离演练全部通过（--stack ${TARGET_STACK}）"
}

main "$@"
