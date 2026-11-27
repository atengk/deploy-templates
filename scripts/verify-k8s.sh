#!/usr/bin/env bash
# 使用 Kustomize 渲染两栈全部 Kubernetes 清单，并按工具链可用性执行 kubeconform 与 trivy config 校验。
#
# @author Ateng
# @since 2026-11-27

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET_STACK="all"
REQUIRE_ALL_TOOLS="${REQUIRE_ALL_TOOLS:-false}"
WORK_TMP=""

usage() {
  cat <<'EOF'
用法：verify-k8s.sh [--stack spring-boot-jar|vue3-pnpm|all] [--require-all-tools]

环境变量：
  REQUIRE_ALL_TOOLS  设为 true 时，若缺少 kubeconform 或 trivy 则严格失败（默认：false）
EOF
}

log_info() {
  printf '[INFO] %s\n' "$*"
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

cleanup() {
  if [[ -n "${WORK_TMP}" && -d "${WORK_TMP}" ]]; then
    rm -rf "${WORK_TMP}"
  fi
}
trap cleanup EXIT

is_true() {
  [[ "${1:-}" == "true" || "${1:-}" == "1" ]]
}

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
    --require-all-tools)
      REQUIRE_ALL_TOOLS="true"
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

if ! command -v kubectl >/dev/null 2>&1; then
  log_error "未找到 kubectl 命令，无法执行 Kustomize 清单渲染"
  exit 1
fi

HAS_KUBECONFORM="false"
HAS_TRIVY="false"

if command -v kubeconform >/dev/null 2>&1; then
  HAS_KUBECONFORM="true"
elif is_true "${REQUIRE_ALL_TOOLS}"; then
  log_error "REQUIRE_ALL_TOOLS=true 但未找到 kubeconform 命令"
  exit 1
else
  log_skip "本机未安装 kubeconform，将跳过严格 Schema 校验"
fi

if command -v trivy >/dev/null 2>&1; then
  HAS_TRIVY="true"
elif is_true "${REQUIRE_ALL_TOOLS}"; then
  log_error "REQUIRE_ALL_TOOLS=true 但未找到 trivy 命令"
  exit 1
else
  log_skip "本机未安装 trivy，将跳过静态安全配置扫描"
fi

verify_k8s_tier() {
  local stack="$1"
  local tier="$2"
  local k8s_dir="${REPO_ROOT}/templates/${stack}/deploy/kubernetes/${tier}"
  local rendered_file="${WORK_TMP}/${stack}-${tier}.yaml"

  if [[ ! -f "${k8s_dir}/kustomization.yaml" ]]; then
    log_error "缺少 kustomization.yaml：${k8s_dir}"
    exit 1
  fi

  log_info "渲染 Kustomize 清单：${stack}/${tier}"
  kubectl kustomize "${k8s_dir}" > "${rendered_file}"
  if [[ ! -s "${rendered_file}" ]]; then
    log_error "Kustomize 渲染输出为空：${k8s_dir}"
    exit 1
  fi

  grep -Fq 'kind: Deployment' "${rendered_file}"
  grep -Fq 'kind: Service' "${rendered_file}"
  grep -Fq 'kind: Ingress' "${rendered_file}"
  if [[ "${tier}" == "production" || "${tier}" == "hardened" ]]; then
    grep -Fq 'kind: ConfigMap' "${rendered_file}"
    grep -Fq 'kind: HorizontalPodAutoscaler' "${rendered_file}"
    grep -Fq 'kind: PodDisruptionBudget' "${rendered_file}"
  fi
  if [[ "${tier}" == "hardened" ]]; then
    grep -Fq 'kind: NetworkPolicy' "${rendered_file}"
  fi
  log_pass "Kustomize 渲染与资源结构断言通过 [${stack}/${tier}]"

  if [[ "${HAS_KUBECONFORM}" == "true" ]]; then
    kubeconform -strict -summary -kubernetes-version 1.30.0 "${rendered_file}"
    log_pass "kubeconform 严格模式 Schema 校验通过 [${stack}/${tier}]"
  fi

  if [[ "${HAS_TRIVY}" == "true" ]]; then
    log_info "Trivy 配置安全报告（HIGH,CRITICAL）[${stack}/${tier}]："
    trivy config --severity HIGH,CRITICAL "${k8s_dir}" || true
    trivy config --severity CRITICAL --exit-code 1 "${k8s_dir}"
    log_pass "trivy config CRITICAL 零阻断校验通过 [${stack}/${tier}]"
  fi
}

main() {
  WORK_TMP="$(mktemp -d)"

  local stacks=()
  case "${TARGET_STACK}" in
    spring-boot-jar) stacks=("spring-boot-jar") ;;
    vue3-pnpm) stacks=("vue3-pnpm") ;;
    all) stacks=("spring-boot-jar" "vue3-pnpm") ;;
  esac

  local stack=""
  local tier=""
  for stack in "${stacks[@]}"; do
    for tier in quickstart production hardened; do
      verify_k8s_tier "${stack}" "${tier}"
    done
  done

  log_info "Kubernetes 清单验证完成（--stack ${TARGET_STACK}）"
}

main "$@"
