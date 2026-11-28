#!/usr/bin/env bash
# 统一构建并打包双技术栈发版产物、宿主机即用部署归档及 SHA-256 校验清单（以传入版本号为唯一真相源，不修改工作区源码）。
#
# @author Ateng
# @since 2026-11-27

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

VERSION="${RELEASE_VERSION:-}"
OUT_DIR="${OUTPUT_DIR:-}"
INSTALL_DEPS="${INSTALL_DEPS:-auto}"
SKIP_TESTS="false"
WORK_TMP=""

usage() {
  cat <<'EOF'
用法：package-release.sh --version <版本号> [--output-dir <输出目录>] [--install-deps auto|always|never] [--skip-tests]
      package-release.sh <版本号> [输出目录]

选项：
  -v, --version <版本号>       必传，注入构建产物与归档命名的发布版本号（例如 v1.0.0 或 v0.0.0-dryrun）
  -o, --output-dir <输出目录>  产物输出目录（默认：<仓库根目录>/dist/release-<版本号>）
  --install-deps <策略>        Vue 3 依赖安装策略：auto（缺失时安装，默认）、always（强制 --frozen-lockfile）、never（跳过安装）
  --skip-tests                 跳过 Spring Boot 3 与 Vue 3 单元测试（适用于前置门禁已执行的流水线复用场景）
  -h, --help                   显示帮助信息
EOF
}

cleanup() {
  if [[ -n "${WORK_TMP}" && -d "${WORK_TMP}" ]]; then
    chmod -R u+rwX "${WORK_TMP}" 2>/dev/null || true
    rm -rf "${WORK_TMP}"
  fi
}
trap cleanup EXIT

read_jar_application_yml() {
  local jar_file="$1"
  local py_cmd=""

  if command -v unzip >/dev/null 2>&1; then
    unzip -p "${jar_file}" "BOOT-INF/classes/application.yml" 2>/dev/null || true
    return 0
  fi

  if py_cmd="$(detect_python zipfile)"; then
    JAR_FILE="${jar_file}" "${py_cmd}" - <<'PYEOF'
import os
import zipfile

with zipfile.ZipFile(os.environ["JAR_FILE"], "r") as zf:
    print(zf.read("BOOT-INF/classes/application.yml").decode("utf-8"))
PYEOF
    return 0
  fi

  log_error "缺少 unzip 与 python zipfile 支持，无法检查 Jar 内部版本注入"
  return 1
}

validate_version() {
  local ver="$1"
  if [[ -z "${ver}" ]]; then
    log_error "必须通过 --version 或位置参数提供发布版本号"
    usage >&2
    exit 1
  fi
  if [[ "${ver}" == "." || "${ver}" == ".." || ! "${ver}" =~ ^[A-Za-z0-9._+-]+$ ]]; then
    log_error "版本号格式非法：${ver}（仅允许字母、数字、点、下划线、加号与连字符）"
    exit 1
  fi
}

require_build_tools() {
  local cmd=""
  for cmd in mvn node pnpm tar sha256sum; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      log_error "缺少必需构建工具：${cmd}"
      exit 1
    fi
  done
}

# 仅复制白名单内的部署文档、脚本、服务单元、Nginx 配置与示例环境文件，绝不带入真实 .env
copy_systemd_tier_files() {
  local src_systemd_dir="$1"
  local dst_systemd_dir="$2"
  local tier=""
  local file=""
  local base=""

  mkdir -p "${dst_systemd_dir}"
  cp -f "${src_systemd_dir}/README.md" "${dst_systemd_dir}/README.md"
  chmod 0644 "${dst_systemd_dir}/README.md"

  for tier in quickstart production hardened; do
    local src_tier="${src_systemd_dir}/${tier}"
    local dst_tier="${dst_systemd_dir}/${tier}"
    [[ -d "${src_tier}" ]] || {
      log_error "缺少宿主机等级目录：${src_tier}"
      exit 1
    }
    mkdir -p "${dst_tier}"

    for file in "${src_tier}"/*; do
      [[ -f "${file}" ]] || continue
      base="$(basename "${file}")"
      case "${base}" in
        *.sh)
          cp -f "${file}" "${dst_tier}/${base}"
          chmod 0755 "${dst_tier}/${base}"
          ;;
        *.service|*.conf|*.env.example|*.md)
          cp -f "${file}" "${dst_tier}/${base}"
          chmod 0644 "${dst_tier}/${base}"
          ;;
        *)
          log_info "跳过非模板白名单文件：${file}"
          ;;
      esac
    done
  done
}

# 验证暂存目录无真实 .env 文件与敏感凭据（复用公共安全扫描）
verify_stage_clean_and_safe() {
  local stage_dir="$1"
  local label="$2"
  verify_dir_clean_and_safe "${stage_dir}" "${label}" || exit 1
}

build_spring_boot_artifacts() {
  local sb_app_dir="${REPO_ROOT}/templates/spring-boot-jar/app"
  local sb_systemd_dir="${REPO_ROOT}/templates/spring-boot-jar/deploy/systemd"
  local target_jar="${sb_app_dir}/target/app.jar"
  local out_jar_name="spring-boot-jar-${VERSION}.jar"
  local out_jar_path="${OUT_DIR}/${out_jar_name}"
  local out_sys_name="spring-boot-jar-systemd-${VERSION}.tar.gz"
  local out_sys_path="${OUT_DIR}/${out_sys_name}"

  if [[ "${SKIP_TESTS}" != "true" ]]; then
    log_info "运行 Spring Boot 3 参考应用测试..."
    mvn -B -ntp -f "${sb_app_dir}/pom.xml" test
  fi

  log_info "以版本号 ${VERSION} 构建 Spring Boot 3 可执行 Jar（不修改 pom.xml）..."
  mvn -B -ntp -f "${sb_app_dir}/pom.xml" clean package -DskipTests "-Dapp.version=${VERSION}"

  if [[ ! -f "${target_jar}" || ! -s "${target_jar}" ]]; then
    log_error "Spring Boot 3 构建产物缺失或为空：${target_jar}"
    exit 1
  fi

  cp -f "${target_jar}" "${out_jar_path}"

  # 验证版本号已由 Maven 资源过滤正确写入 Jar 内配置
  local app_yml=""
  app_yml="$(read_jar_application_yml "${out_jar_path}")"
  if [[ -z "${app_yml}" ]]; then
    log_error "未能从 ${out_jar_path} 读取 BOOT-INF/classes/application.yml"
    exit 1
  fi
  if grep -Fq '@app.version@' <<< "${app_yml}"; then
    log_error "Jar 内 application.yml 仍残留未替换的 @app.version@"
    exit 1
  fi
  if ! grep -Fq "${VERSION}" <<< "${app_yml}"; then
    log_error "Jar 内 application.yml 未注入目标版本号：${VERSION}"
    exit 1
  fi
  log_pass "Spring Boot 3 Jar 构建与版本注入验证通过：${out_jar_name}"

  # 组装并打包 Spring Boot 3 宿主机即用部署归档
  local stage_name="spring-boot-jar-systemd-${VERSION}"
  local stage_root="${WORK_TMP}/${stage_name}"
  mkdir -p "${stage_root}"
  cp -f "${sb_systemd_dir}/README.md" "${stage_root}/README.md"
  chmod 0644 "${stage_root}/README.md"
  cp -f "${out_jar_path}" "${stage_root}/app.jar"
  chmod 0644 "${stage_root}/app.jar"
  copy_systemd_tier_files "${sb_systemd_dir}" "${stage_root}/deploy/systemd"
  verify_stage_clean_and_safe "${stage_root}" "spring-boot-jar-systemd"

  tar -C "${WORK_TMP}" -czf "${out_sys_path}" "${stage_name}"
  if [[ ! -s "${out_sys_path}" ]]; then
    log_error "Spring Boot 3 宿主机归档打包失败：${out_sys_path}"
    exit 1
  fi
  log_pass "Spring Boot 3 宿主机即用部署归档生成通过：${out_sys_name}"
}

build_vue3_artifacts() {
  local vue_app_dir="${REPO_ROOT}/templates/vue3-pnpm/app"
  local vue_systemd_dir="${REPO_ROOT}/templates/vue3-pnpm/deploy/systemd"
  local dist_dir="${vue_app_dir}/dist"
  local out_dist_name="vue3-pnpm-dist-${VERSION}.tar.gz"
  local out_dist_path="${OUT_DIR}/${out_dist_name}"
  local out_sys_name="vue3-pnpm-systemd-${VERSION}.tar.gz"
  local out_sys_path="${OUT_DIR}/${out_sys_name}"

  local need_install="false"
  case "${INSTALL_DEPS}" in
    always)
      need_install="true"
      ;;
    auto)
      if [[ ! -d "${vue_app_dir}/node_modules" || ! -e "${vue_app_dir}/node_modules/.bin/vite" ]]; then
        need_install="true"
      fi
      ;;
    never)
      need_install="false"
      ;;
    *)
      log_error "无效的 --install-deps 策略：${INSTALL_DEPS}（仅允许 auto、always、never）"
      exit 1
      ;;
  esac

  if [[ "${need_install}" == "true" ]]; then
    log_info "安装 Vue 3 依赖（pnpm install --frozen-lockfile）..."
    if [[ -n "${PNPM_REGISTRY:-}" ]]; then
      pnpm --dir "${vue_app_dir}" install --frozen-lockfile --registry="${PNPM_REGISTRY}"
    else
      pnpm --dir "${vue_app_dir}" install --frozen-lockfile
    fi
  fi

  if [[ "${SKIP_TESTS}" != "true" ]]; then
    log_info "运行 Vue 3 参考应用 Vitest 单元测试..."
    pnpm --dir "${vue_app_dir}" test
  fi

  log_info "以版本号 ${VERSION} 构建 Vue 3 静态产物（注入 VITE_APP_VERSION，不修改 package.json）..."
  rm -rf "${dist_dir}"
  VITE_APP_VERSION="${VERSION}" pnpm --dir "${vue_app_dir}" build

  if [[ ! -f "${dist_dir}/index.html" || ! -d "${dist_dir}/assets" ]]; then
    log_error "Vue 3 静态构建产物不完整：${dist_dir}"
    exit 1
  fi
  if ! grep -rFq "${VERSION}" "${dist_dir}/assets"; then
    log_error "Vue 3 静态资源中未检测到注入的 VITE_APP_VERSION=${VERSION}"
    exit 1
  fi

  tar -C "${vue_app_dir}" -czf "${out_dist_path}" dist
  if [[ ! -s "${out_dist_path}" ]]; then
    log_error "Vue 3 静态归档打包失败：${out_dist_path}"
    exit 1
  fi
  log_pass "Vue 3 静态产物归档与版本注入验证通过：${out_dist_name}"

  # 组装并打包 Vue 3 宿主机即用部署归档
  local stage_name="vue3-pnpm-systemd-${VERSION}"
  local stage_root="${WORK_TMP}/${stage_name}"
  mkdir -p "${stage_root}/dist"
  cp -f "${vue_systemd_dir}/README.md" "${stage_root}/README.md"
  chmod 0644 "${stage_root}/README.md"
  cp -a "${dist_dir}/." "${stage_root}/dist/"
  copy_systemd_tier_files "${vue_systemd_dir}" "${stage_root}/deploy/systemd"
  verify_stage_clean_and_safe "${stage_root}" "vue3-pnpm-systemd"

  tar -C "${WORK_TMP}" -czf "${out_sys_path}" "${stage_name}"
  if [[ ! -s "${out_sys_path}" ]]; then
    log_error "Vue 3 宿主机归档打包失败：${out_sys_path}"
    exit 1
  fi
  log_pass "Vue 3 宿主机即用部署归档生成通过：${out_sys_name}"
}

generate_and_verify_checksums() {
  local artifacts=(
    "spring-boot-jar-${VERSION}.jar"
    "vue3-pnpm-dist-${VERSION}.tar.gz"
    "spring-boot-jar-systemd-${VERSION}.tar.gz"
    "vue3-pnpm-systemd-${VERSION}.tar.gz"
  )
  local sbom=""
  local optional_sboms=(
    "spring-boot-jar-${VERSION}-hardened.spdx.json"
    "vue3-pnpm-${VERSION}-hardened.spdx.json"
  )

  for sbom in "${optional_sboms[@]}"; do
    if [[ -f "${OUT_DIR}/${sbom}" && -s "${OUT_DIR}/${sbom}" ]]; then
      artifacts+=("${sbom}")
    fi
  done

  (
    cd "${OUT_DIR}"
    sha256sum "${artifacts[@]}" > SHA256SUMS.txt
    sha256sum -c SHA256SUMS.txt
  )
  log_pass "已生成并自检通过 SHA256SUMS.txt（共 ${#artifacts[@]} 个发版产物）"
}

parse_args() {
  local positional=()
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -v|--version)
        if [[ "$#" -lt 2 || -z "$2" ]]; then
          log_error "--version 缺少参数值"
          exit 1
        fi
        VERSION="$2"
        shift 2
        ;;
      -o|--output-dir)
        if [[ "$#" -lt 2 || -z "$2" ]]; then
          log_error "--output-dir 缺少参数值"
          exit 1
        fi
        OUT_DIR="$2"
        shift 2
        ;;
      --install-deps)
        if [[ "$#" -lt 2 || -z "$2" ]]; then
          log_error "--install-deps 缺少参数值"
          exit 1
        fi
        INSTALL_DEPS="$2"
        shift 2
        ;;
      --skip-tests)
        SKIP_TESTS="true"
        shift
        ;;
      --)
        shift
        while [[ "$#" -gt 0 ]]; do
          positional+=("$1")
          shift
        done
        ;;
      -*)
        log_error "未知参数：$1"
        usage >&2
        exit 1
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if [[ "${#positional[@]}" -ge 1 && -z "${VERSION}" ]]; then
    VERSION="${positional[0]}"
  fi
  if [[ "${#positional[@]}" -ge 2 && -z "${OUT_DIR}" ]]; then
    OUT_DIR="${positional[1]}"
  fi
  if [[ "${#positional[@]}" -gt 2 ]]; then
    log_error "位置参数过多"
    usage >&2
    exit 1
  fi
}

main() {
  parse_args "$@"
  validate_version "${VERSION}"
  require_build_tools

  if [[ -z "${OUT_DIR}" ]]; then
    OUT_DIR="${REPO_ROOT}/dist/release-${VERSION}"
  fi
  mkdir -p "${OUT_DIR}"
  OUT_DIR="$(cd "${OUT_DIR}" && pwd)"

  WORK_TMP="$(mktemp -d)"

  log_info "开始统一发版打包（版本：${VERSION}，输出目录：${OUT_DIR}）"
  build_spring_boot_artifacts
  build_vue3_artifacts
  generate_and_verify_checksums
  log_info "全部发版产物构建与校验完成：${OUT_DIR}"
}

main "$@"
