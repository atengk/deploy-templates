#!/usr/bin/env bash
# 构建并拉起两栈全部等级 Docker 容器与 Compose 编排，黑盒实测外部 HTTP 契约与安全运行时约束。
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
SKIP_DOCKER="false"
SKIP_COMPOSE="false"
PRUNE_IMAGES="false"

usage() {
  cat <<'EOF'
用法：verify-containers.sh [--stack spring-boot-jar|vue3-pnpm|all] [--skip-docker] [--skip-compose] [--prune-images]

选项：
  --stack <栈名>    指定验证的技术栈（默认：all）
  --skip-docker     跳过单容器 docker build/run 验证
  --skip-compose    跳过 docker compose 编排验证
  --prune-images    验证结束后删除本次构建的测试镜像（默认保留供后续 Trivy 扫描）
EOF
}

ACTIVE_CONTAINERS=()
ACTIVE_COMPOSE_FILES=()
ACTIVE_COMPOSE_PROJECTS=()
BUILT_IMAGES=()
WORK_TMP=""

cleanup() {
  local i=0
  local cid=""
  for cid in "${ACTIVE_CONTAINERS[@]+"${ACTIVE_CONTAINERS[@]}"}"; do
    docker rm -f "${cid}" >/dev/null 2>&1 || true
  done

  for ((i = 0; i < ${#ACTIVE_COMPOSE_PROJECTS[@]}; i++)); do
    docker compose -p "${ACTIVE_COMPOSE_PROJECTS[i]}" -f "${ACTIVE_COMPOSE_FILES[i]}" down -v --remove-orphans >/dev/null 2>&1 || true
  done

  if [[ "${PRUNE_IMAGES}" == "true" ]]; then
    local img=""
    for img in "${BUILT_IMAGES[@]+"${BUILT_IMAGES[@]}"}"; do
      docker image rm -f "${img}" >/dev/null 2>&1 || true
    done
  fi

  if [[ -n "${WORK_TMP}" && -d "${WORK_TMP}" ]]; then
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
    --skip-docker)
      SKIP_DOCKER="true"
      shift
      ;;
    --skip-compose)
      SKIP_COMPOSE="true"
      shift
      ;;
    --prune-images)
      PRUNE_IMAGES="true"
      shift
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

require_docker_tools() {
  if ! command -v docker >/dev/null 2>&1; then
    log_error "未找到 docker 命令，请在已安装 Docker 的环境中执行容器实测"
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    log_error "Docker 守护进程不可用或当前用户无访问权限"
    exit 1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    log_error "未检测到 docker compose 插件（v2+）"
    exit 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log_error "未找到 curl 命令"
    exit 1
  fi
}

NEXT_FALLBACK_PORT=18100
pick_free_port() {
  local py_cmd=""
  if py_cmd="$(detect_python socket)"; then
    "${py_cmd}" -c "import socket; s=socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1]); s.close()"
    return 0
  fi
  NEXT_FALLBACK_PORT=$((NEXT_FALLBACK_PORT + 1))
  printf '%s\n' "${NEXT_FALLBACK_PORT}"
}

wait_http_200() {
  local url="$1"
  local timeout_sec="${2:-60}"
  local elapsed=0
  local code=""
  while [[ "${elapsed}" -lt "${timeout_sec}" ]]; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3 "${url}" 2>/dev/null || true)"
    if [[ "${code}" == "200" ]]; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  log_error "等待 HTTP 200 超时（${timeout_sec}s）：${url}（最后状态码：${code:-无响应}）"
  return 1
}

wait_container_healthy() {
  local container="$1"
  local timeout_sec="${2:-90}"
  local elapsed=0
  local status=""
  while [[ "${elapsed}" -lt "${timeout_sec}" ]]; do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${container}" 2>/dev/null || printf 'unknown')"
    if [[ "${status}" == "healthy" ]]; then
      return 0
    fi
    if [[ "${status}" == "unhealthy" ]]; then
      log_error "容器健康检查进入 unhealthy 状态：${container}"
      docker logs --tail 50 "${container}" >&2 || true
      return 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  log_error "等待容器变为 healthy 超时（${timeout_sec}s）：${container}（当前状态：${status}）"
  docker logs --tail 50 "${container}" >&2 || true
  return 1
}

http_get_assert() {
  local url="$1"
  local expected_code="$2"
  local body_file="$3"
  local header_file="$4"
  local actual_code=""

  actual_code="$(curl -sS -D "${header_file}" -o "${body_file}" -w '%{http_code}' --connect-timeout 3 --max-time 5 "${url}")"
  if [[ "${actual_code}" != "${expected_code}" ]]; then
    log_error "HTTP 状态码断言失败：${url} 期望 ${expected_code}，实际 ${actual_code}"
    return 1
  fi
}

assert_body_contains() {
  local body_file="$1"
  local pattern="$2"
  local desc="$3"
  if ! grep -Fq -- "${pattern}" "${body_file}"; then
    log_error "响应正文缺少预期内容（${desc}）：${pattern}"
    cat "${body_file}" >&2 || true
    return 1
  fi
}

assert_header_matches() {
  local header_file="$1"
  local regex="$2"
  local desc="$3"
  if ! tr -d '\r' < "${header_file}" | grep -iqE -- "${regex}"; then
    log_error "响应头未匹配预期约束（${desc}）：${regex}"
    tr -d '\r' < "${header_file}" >&2 || true
    return 1
  fi
}

assert_graceful_sigterm_exit() {
  local container="$1"
  local timeout_sec="${2:-30}"
  local exit_code=""

  docker kill --signal=SIGTERM "${container}" >/dev/null
  exit_code="$(timeout "${timeout_sec}" docker wait "${container}" 2>/dev/null || true)"
  if [[ -z "${exit_code}" ]]; then
    log_error "容器响应 SIGTERM 退出超时（${timeout_sec}s）：${container}"
    return 1
  fi
  # Java 进程收到 SIGTERM 通常返回 143（128+15）或 0，绝对不可是 SIGKILL(137)
  if [[ "${exit_code}" != "0" && "${exit_code}" != "143" ]]; then
    log_error "容器 SIGTERM 退出码异常（期望 0 或 143，实际 ${exit_code}）：${container}"
    docker logs --tail 30 "${container}" >&2 || true
    return 1
  fi
}

remove_container() {
  local cid="$1"
  docker rm -f "${cid}" >/dev/null 2>&1 || true
  local updated=()
  local item=""
  for item in "${ACTIVE_CONTAINERS[@]+"${ACTIVE_CONTAINERS[@]}"}"; do
    [[ "${item}" != "${cid}" ]] && updated+=("${item}")
  done
  ACTIVE_CONTAINERS=("${updated[@]+"${updated[@]}"}")
}

compose_down() {
  local proj="$1"
  local compose_file="$2"
  docker compose -p "${proj}" -f "${compose_file}" down -v --remove-orphans >/dev/null 2>&1 || true
  local next_projs=()
  local next_files=()
  local i=0
  for ((i = 0; i < ${#ACTIVE_COMPOSE_PROJECTS[@]}; i++)); do
    if [[ "${ACTIVE_COMPOSE_PROJECTS[i]}" != "${proj}" ]]; then
      next_projs+=("${ACTIVE_COMPOSE_PROJECTS[i]}")
      next_files+=("${ACTIVE_COMPOSE_FILES[i]}")
    fi
  done
  ACTIVE_COMPOSE_PROJECTS=("${next_projs[@]+"${next_projs[@]}"}")
  ACTIVE_COMPOSE_FILES=("${next_files[@]+"${next_files[@]}"}")
}

build_spring_boot_image() {
  local tier="$1"
  local image="ghcr.io/atengk/deploy-templates/spring-boot-jar:${tier}"
  local dockerfile="${REPO_ROOT}/templates/spring-boot-jar/deploy/docker/${tier}/Dockerfile"
  local context="${REPO_ROOT}/templates/spring-boot-jar/app"
  local args=(
    build
    -f "${dockerfile}"
    --build-arg "APP_VERSION=${APP_VERSION:-0.1.0-ci}"
    -t "${image}"
  )

  if [[ -n "${BASE_IMAGE_REGISTRY:-}" ]]; then
    args+=(--build-arg "BASE_IMAGE_REGISTRY=${BASE_IMAGE_REGISTRY}")
  fi
  if [[ "${tier}" == "hardened" && -n "${GCR_REGISTRY:-}" ]]; then
    args+=(--build-arg "GCR_REGISTRY=${GCR_REGISTRY}")
  fi
  if [[ -n "${MAVEN_MIRROR_URL:-}" ]]; then
    args+=(--build-arg "MAVEN_MIRROR_URL=${MAVEN_MIRROR_URL}")
  fi
  args+=("${context}")

  log_info "构建 Spring Boot 3 镜像 [${tier}] -> ${image}"
  docker "${args[@]}"
  BUILT_IMAGES+=("${image}")
}

# 统一校验运行中容器的非 root 用户与只读根文件系统约束
assert_container_runtime_security() {
  local cid="$1"
  local label="$2"
  local expected_exec_uid="$3"
  local expected_config_user="$4"
  local require_ro="$5"
  local ro_probe_path="${6:-}"

  if [[ -n "${expected_exec_uid}" ]]; then
    local actual_uid=""
    actual_uid="$(docker exec "${cid}" id -u)"
    if [[ "${actual_uid}" != "${expected_exec_uid}" ]]; then
      log_error "${label} 非 root UID 校验失败（期望 ${expected_exec_uid}，实际 ${actual_uid}）"
      return 1
    fi
  fi

  if [[ -n "${expected_config_user}" ]]; then
    local actual_user=""
    actual_user="$(docker inspect --format '{{.Config.User}}' "${cid}")"
    if [[ "${actual_user}" != "${expected_config_user}" ]]; then
      log_error "${label} 运行用户配置校验失败（期望 ${expected_config_user}，实际 ${actual_user}）"
      return 1
    fi
  fi

  if [[ "${require_ro}" == "true" ]]; then
    local ro_flag=""
    ro_flag="$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "${cid}")"
    if [[ "${ro_flag}" != "true" ]]; then
      log_error "${label} 只读根文件系统校验失败（期望 ReadonlyRootfs=true，实际 ${ro_flag}）"
      return 1
    fi
    if [[ -n "${ro_probe_path}" ]] && docker exec "${cid}" touch "${ro_probe_path}" 2>/dev/null; then
      log_error "${label} 静态路径在 read_only 模式下仍被写入：${ro_probe_path}"
      return 1
    fi
  fi
}

assert_spring_boot_no_otlp_errors() {
  local cid="$1"
  if docker logs "${cid}" 2>&1 | grep -qiE '(Failed to export spans|Connection refused.*431[78])'; then
    log_error "容器日志检测到意外的 OTLP 连接报错（${cid}）"
    docker logs --tail 50 "${cid}" >&2 || true
    return 1
  fi
}

# 统一校验 Spring Boot 3 在 Docker 与 Compose 模式下的安全约束、HTTP 契约、管理端口隔离与优雅停机
verify_spring_boot_running_instance() {
  local mode="$1"
  local tier="$2"
  local cid="$3"
  local port="$4"
  local mgmt_port="$5"
  local body_file="$6"
  local hdr_file="$7"
  local label="Spring Boot ${mode} ${tier}"

  if [[ "${tier}" == "quickstart" ]]; then
    wait_http_200 "http://127.0.0.1:${port}/api/info" 60
    http_get_assert "http://127.0.0.1:${port}/api/info" "200" "${body_file}" "${hdr_file}"
    assert_body_contains "${body_file}" '"application":"spring-boot-jar-app"' "${label} /api/info"
    assert_body_contains "${body_file}" '"otlpEnabled":false' "${label} OTLP 默认关闭"

    http_get_assert "http://127.0.0.1:${port}/actuator/health" "200" "${body_file}" "${hdr_file}"
    assert_body_contains "${body_file}" '"status":"UP"' "${label} /actuator/health"
    assert_spring_boot_no_otlp_errors "${cid}"
    return 0
  fi

  wait_container_healthy "${cid}" 90
  if [[ "${tier}" == "production" ]]; then
    assert_container_runtime_security "${cid}" "${label}" "10001" "" "false"
  else
    assert_container_runtime_security "${cid}" "${label}" "" "65532:65532" "true"
  fi

  http_get_assert "http://127.0.0.1:${port}/api/info" "200" "${body_file}" "${hdr_file}"
  assert_body_contains "${body_file}" '"managementPort":8081' "${label} 独立管理端口 8081"
  assert_body_contains "${body_file}" '"otlpEnabled":false' "${label} OTLP 默认关闭"
  http_get_assert "http://127.0.0.1:${port}/actuator/health" "404" "${body_file}" "${hdr_file}"

  if [[ "${tier}" == "hardened" ]]; then
    docker exec "${cid}" java -Xms8m -Xmx32m -cp /app/app.jar com.ateng.deploy.HealthCheck
  fi

  if [[ -n "${mgmt_port}" ]]; then
    http_get_assert "http://127.0.0.1:${mgmt_port}/actuator/health/readiness" "200" "${body_file}" "${hdr_file}"
    assert_body_contains "${body_file}" '"status":"UP"' "${label} readiness"
    http_get_assert "http://127.0.0.1:${mgmt_port}/actuator/prometheus" "200" "${body_file}" "${hdr_file}"
    assert_body_contains "${body_file}" '# HELP' "${label} prometheus"
  elif [[ "${tier}" == "production" ]]; then
    docker exec "${cid}" curl -fsS http://127.0.0.1:8081/actuator/health/readiness >/dev/null
    docker exec "${cid}" curl -fsS http://127.0.0.1:8081/actuator/prometheus | grep -Fq '# HELP'
  fi

  assert_spring_boot_no_otlp_errors "${cid}"

  if [[ "${mode}" == "docker" || "${tier}" == "hardened" ]]; then
    assert_graceful_sigterm_exit "${cid}" 30
  fi
}

verify_spring_boot_docker_tier() {
  local tier="$1"
  local image="ghcr.io/atengk/deploy-templates/spring-boot-jar:${tier}"
  local env_file="${REPO_ROOT}/templates/spring-boot-jar/deploy/docker/${tier}/.env.example"
  local cname="dt-verify-sb-${tier}-$$"
  local port=""
  local mgmt_port=""
  local body_file="${WORK_TMP}/sb-docker-${tier}.body"
  local hdr_file="${WORK_TMP}/sb-docker-${tier}.hdr"
  local run_args=(run -d --name "${cname}")

  port="$(pick_free_port)"
  run_args+=(-p "127.0.0.1:${port}:8080")

  if [[ "${tier}" != "quickstart" ]]; then
    mgmt_port="$(pick_free_port)"
    run_args+=(-p "127.0.0.1:${mgmt_port}:8081" --memory=512m)
  fi
  if [[ "${tier}" == "hardened" ]]; then
    run_args+=(
      --read-only
      --tmpfs "/tmp:rw,noexec,nosuid,size=64m"
      --cap-drop=ALL
      --security-opt=no-new-privileges:true
    )
  fi
  run_args+=(--env-file "${env_file}" "${image}")

  docker "${run_args[@]}" >/dev/null
  ACTIVE_CONTAINERS+=("${cname}")

  verify_spring_boot_running_instance "docker" "${tier}" "${cname}" "${port}" "${mgmt_port}" "${body_file}" "${hdr_file}"

  remove_container "${cname}"
  log_pass "Spring Boot 3 Docker 容器契约实测通过 [${tier}]"
}

verify_spring_boot_compose_tier() {
  local tier="$1"
  local compose_dir="${REPO_ROOT}/templates/spring-boot-jar/deploy/compose/${tier}"
  local compose_file="${compose_dir}/compose.yaml"
  local env_file="${compose_dir}/.env.example"
  local proj="dt-sb-${tier}-$$"
  local port=""
  local body_file="${WORK_TMP}/sb-compose-${tier}.body"
  local hdr_file="${WORK_TMP}/sb-compose-${tier}.hdr"

  port="$(pick_free_port)"
  ACTIVE_COMPOSE_PROJECTS+=("${proj}")
  ACTIVE_COMPOSE_FILES+=("${compose_file}")

  APP_PORT="${port}" APP_VERSION="${APP_VERSION:-0.1.0-ci}" \
    docker compose -p "${proj}" -f "${compose_file}" --env-file "${env_file}" config >/dev/null

  APP_PORT="${port}" APP_VERSION="${APP_VERSION:-0.1.0-ci}" \
    docker compose -p "${proj}" -f "${compose_file}" --env-file "${env_file}" up -d --build

  local cid=""
  cid="$(docker compose -p "${proj}" -f "${compose_file}" ps -q app)"

  verify_spring_boot_running_instance "compose" "${tier}" "${cid}" "${port}" "" "${body_file}" "${hdr_file}"

  compose_down "${proj}" "${compose_file}"
  log_pass "Spring Boot 3 Compose 编排契约实测通过 [${tier}]"
}

build_vue3_image() {
  local tier="$1"
  local image="ghcr.io/atengk/deploy-templates/vue3-pnpm:${tier}"
  local dockerfile="${REPO_ROOT}/templates/vue3-pnpm/deploy/docker/${tier}/Dockerfile"
  local context="${REPO_ROOT}/templates/vue3-pnpm"
  local args=(
    build
    -f "${dockerfile}"
    --build-arg "APP_VERSION=${APP_VERSION:-1.0.0-ci}"
    -t "${image}"
  )

  if [[ -n "${BASE_IMAGE_REGISTRY:-}" ]]; then
    args+=(--build-arg "BASE_IMAGE_REGISTRY=${BASE_IMAGE_REGISTRY}")
  fi
  if [[ -n "${PNPM_REGISTRY:-}" ]]; then
    args+=(--build-arg "PNPM_REGISTRY=${PNPM_REGISTRY}")
  fi
  args+=("${context}")

  log_info "构建 Vue 3 镜像 [${tier}] -> ${image}"
  docker "${args[@]}"
  BUILT_IMAGES+=("${image}")
}

extract_first_asset_path() {
  local html_file="$1"
  grep -oE '/assets/[A-Za-z0-9._-]+\.(js|css)' "${html_file}" | head -n 1 || true
}

verify_vue3_http_endpoints() {
  local tier="$1"
  local base_url="$2"
  local expected_api_url="$3"
  local body_file="$4"
  local hdr_file="$5"
  local expect_omitted_version="${6:-false}"

  http_get_assert "${base_url}/healthz" "200" "${body_file}" "${hdr_file}"
  assert_body_contains "${body_file}" "ok" "${tier} /healthz"

  http_get_assert "${base_url}/" "200" "${body_file}" "${hdr_file}"
  assert_body_contains "${body_file}" '<script src="/config.js">' "${tier} 入口页脚本引用"
  local asset_path=""
  asset_path="$(extract_first_asset_path "${body_file}")"
  if [[ -z "${asset_path}" ]]; then
    log_error "未能从 ${base_url}/ 解析到带哈希的 /assets/ 构建资源"
    return 1
  fi

  http_get_assert "${base_url}/orders/deep/123" "200" "${body_file}" "${hdr_file}"
  assert_body_contains "${body_file}" '<div id="app">' "${tier} SPA 深层路由回退"

  if [[ "${tier}" == "quickstart" ]]; then
    return 0
  fi

  assert_header_matches "${hdr_file}" '^Cache-Control:.*no-store' "${tier} SPA 路由禁缓存头"

  http_get_assert "${base_url}/index.html" "200" "${body_file}" "${hdr_file}"
  assert_header_matches "${hdr_file}" '^Cache-Control:.*no-store' "${tier} index.html 禁缓存头"

  http_get_assert "${base_url}${asset_path}" "200" "${body_file}" "${hdr_file}"
  assert_header_matches "${hdr_file}" '^Cache-Control:.*immutable' "${tier} 哈希静态资源长缓存头"
  assert_header_matches "${hdr_file}" '^Cache-Control:.*max-age=31536000' "${tier} 哈希静态资源 1 年缓存"

  http_get_assert "${base_url}/config.js" "200" "${body_file}" "${hdr_file}"
  assert_header_matches "${hdr_file}" '^Cache-Control:.*no-store' "${tier} /config.js 禁缓存头"
  assert_header_matches "${hdr_file}" '^X-Content-Type-Options:[[:space:]]*nosniff' "${tier} X-Content-Type-Options"
  assert_header_matches "${hdr_file}" '^X-Frame-Options:[[:space:]]*DENY' "${tier} X-Frame-Options"
  assert_header_matches "${hdr_file}" '^Referrer-Policy:' "${tier} Referrer-Policy"
  assert_body_contains "${body_file}" 'window.__APP_CONFIG__' "${tier} /config.js 全局配置对象"
  assert_body_contains "${body_file}" "${expected_api_url}" "${tier} /config.js 动态注入 APP_API_BASE_URL"
  if [[ "${expect_omitted_version}" == "true" ]] && grep -Fq 'APP_VERSION' "${body_file}"; then
    log_error "${tier} 未显式传入 APP_VERSION 时，/config.js 不应写入 APP_VERSION 覆盖构建期版本"
    cat "${body_file}" >&2 || true
    return 1
  fi

  if [[ "${tier}" == "hardened" ]]; then
    assert_header_matches "${hdr_file}" '^Content-Security-Policy:' "hardened CSP 安全头"
    assert_header_matches "${hdr_file}" '^Permissions-Policy:' "hardened Permissions-Policy 安全头"
    assert_header_matches "${hdr_file}" '^Cross-Origin-Opener-Policy:[[:space:]]*same-origin' "hardened COOP"
    assert_header_matches "${hdr_file}" '^Cross-Origin-Resource-Policy:[[:space:]]*same-origin' "hardened CORP"

    local post_code=""
    post_code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${base_url}/")"
    if [[ "${post_code}" != "405" ]]; then
      log_error "Vue 3 hardened 非只读方法拦截失败：POST / 期望 405，实际 ${post_code}"
      return 1
    fi
  fi
}

# 统一校验 Vue 3 在 Docker 与 Compose 模式下的运行时安全约束与 HTTP 响应契约
verify_vue3_running_instance() {
  local mode="$1"
  local tier="$2"
  local cid="$3"
  local port="$4"
  local api_url="$5"
  local body_file="$6"
  local hdr_file="$7"
  local expect_omitted_version="$8"
  local label="Vue 3 ${mode} ${tier}"

  if [[ "${tier}" == "quickstart" ]]; then
    wait_http_200 "http://127.0.0.1:${port}/healthz" 30
  else
    wait_container_healthy "${cid}" 45
    if [[ "${tier}" == "hardened" ]]; then
      local probe_path=""
      if [[ "${mode}" == "docker" ]]; then
        probe_path="/usr/share/nginx/html/ro-check"
      fi
      assert_container_runtime_security "${cid}" "${label}" "101" "" "true" "${probe_path}"
    else
      assert_container_runtime_security "${cid}" "${label}" "101" "" "false"
    fi
  fi

  verify_vue3_http_endpoints "${tier}" "http://127.0.0.1:${port}" "${api_url}" "${body_file}" "${hdr_file}" "${expect_omitted_version}"
}

verify_vue3_docker_tier() {
  local tier="$1"
  local image="ghcr.io/atengk/deploy-templates/vue3-pnpm:${tier}"
  local cname="dt-verify-vue-${tier}-$$"
  local port=""
  local api_url="https://api-${tier}.ci.example.com/v1"
  local body_file="${WORK_TMP}/vue-docker-${tier}.body"
  local hdr_file="${WORK_TMP}/vue-docker-${tier}.hdr"
  local run_args=(run -d --name "${cname}")
  local expect_omitted_version="false"

  port="$(pick_free_port)"

  if [[ "${tier}" == "quickstart" ]]; then
    run_args+=(-p "127.0.0.1:${port}:80")
  else
    expect_omitted_version="true"
    run_args+=(-p "127.0.0.1:${port}:8080")
    local app_env="staging"
    if [[ "${tier}" == "hardened" ]]; then
      app_env="production"
      run_args+=(
        --read-only
        --tmpfs "/tmp:rw,noexec,nosuid,nodev,size=32m,mode=1777"
        --cap-drop=ALL
        --security-opt=no-new-privileges:true
        -e "APP_VERSION="
      )
    fi
    run_args+=(
      -e "APP_TITLE=Vue3-CI-${tier}"
      -e "APP_ENV=${app_env}"
      -e "APP_API_BASE_URL=${api_url}"
    )
  fi
  run_args+=("${image}")

  docker "${run_args[@]}" >/dev/null
  ACTIVE_CONTAINERS+=("${cname}")

  verify_vue3_running_instance "docker" "${tier}" "${cname}" "${port}" "${api_url}" "${body_file}" "${hdr_file}" "${expect_omitted_version}"

  remove_container "${cname}"
  log_pass "Vue 3 Docker 容器契约实测通过 [${tier}]"
}

verify_vue3_compose_tier() {
  local tier="$1"
  local compose_dir="${REPO_ROOT}/templates/vue3-pnpm/deploy/compose/${tier}"
  local compose_file="${compose_dir}/compose.yaml"
  local env_file="${compose_dir}/.env.example"
  local proj="dt-vue-${tier}-$$"
  local port=""
  local api_url="https://compose-${tier}.ci.example.com/api"
  local body_file="${WORK_TMP}/vue-compose-${tier}.body"
  local hdr_file="${WORK_TMP}/vue-compose-${tier}.hdr"
  local expect_omitted_version="true"
  local runtime_app_version="${APP_VERSION:-}"

  if [[ -n "${runtime_app_version}" ]]; then
    expect_omitted_version="false"
  fi

  port="$(pick_free_port)"
  ACTIVE_COMPOSE_PROJECTS+=("${proj}")
  ACTIVE_COMPOSE_FILES+=("${compose_file}")

  APP_PORT="${port}" APP_VERSION="${runtime_app_version}" APP_API_BASE_URL="${api_url}" \
    docker compose -p "${proj}" -f "${compose_file}" --env-file "${env_file}" config >/dev/null

  APP_PORT="${port}" APP_VERSION="${runtime_app_version}" APP_API_BASE_URL="${api_url}" \
    docker compose -p "${proj}" -f "${compose_file}" --env-file "${env_file}" up -d --build

  local cid=""
  cid="$(docker compose -p "${proj}" -f "${compose_file}" ps -q app)"

  verify_vue3_running_instance "compose" "${tier}" "${cid}" "${port}" "${api_url}" "${body_file}" "${hdr_file}" "${expect_omitted_version}"

  compose_down "${proj}" "${compose_file}"
  log_pass "Vue 3 Compose 编排契约实测通过 [${tier}]"
}

run_stack_suite() {
  local stack="$1"
  local tier=""
  for tier in quickstart production hardened; do
    if [[ "${stack}" == "spring-boot-jar" ]]; then
      if [[ "${SKIP_DOCKER}" != "true" ]]; then
        build_spring_boot_image "${tier}"
        verify_spring_boot_docker_tier "${tier}"
      fi
      if [[ "${SKIP_COMPOSE}" != "true" ]]; then
        verify_spring_boot_compose_tier "${tier}"
      fi
    else
      if [[ "${SKIP_DOCKER}" != "true" ]]; then
        build_vue3_image "${tier}"
        verify_vue3_docker_tier "${tier}"
      fi
      if [[ "${SKIP_COMPOSE}" != "true" ]]; then
        verify_vue3_compose_tier "${tier}"
      fi
    fi
  done
}

main() {
  require_docker_tools
  WORK_TMP="$(mktemp -d)"

  case "${TARGET_STACK}" in
    spring-boot-jar)
      run_stack_suite "spring-boot-jar"
      ;;
    vue3-pnpm)
      run_stack_suite "vue3-pnpm"
      ;;
    all)
      run_stack_suite "spring-boot-jar"
      run_stack_suite "vue3-pnpm"
      ;;
  esac

  log_info "容器与 Compose 黑盒契约实测全部通过（--stack ${TARGET_STACK}）"
}

main "$@"
