#!/usr/bin/env bash
# 执行仓库级工程基线检查，覆盖 Linux 行尾、脚本权限、文档链接、凭据安全与禁用术语。
#
# @author Ateng
# @since 2026-11-27

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="${DEFAULT_ROOT}"

usage() {
  cat <<'EOF'
用法：verify-repo.sh [--root <仓库根目录>]

检查项：
  1. 面向 Linux 与文本受控文件无 CRLF（\r）行尾
  2. 全仓 *.sh 脚本具备可执行权限（Git 索引 100755 与可执行位）
  3. Markdown 文档无 file:///、本地盘符/家目录绝对路径且站内相对链接真实存在
  4. 全仓文本文件无明显明文凭据或私钥
  5. 全仓文本文件不含 CONTEXT.md 定义的 _Avoid_ 禁用词
EOF
}

FAILURES=0
TEXT_LIST_FILE=""
MD_LIST_FILE=""

cleanup() {
  rm -f "${TEXT_LIST_FILE:-}" "${MD_LIST_FILE:-}"
}
trap cleanup EXIT

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_pass() {
  printf '[PASS] %s\n' "$*"
}

log_fail() {
  printf '[FAIL] %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --root)
      if [[ "$#" -lt 2 || -z "$2" ]]; then
        printf '[ERROR] --root 缺少目录参数\n' >&2
        exit 1
      fi
      REPO_ROOT="$(cd "$2" && pwd)"
      shift 2
      ;;
    *)
      printf '[ERROR] 未知参数：%s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

is_windows_env() {
  case "$(uname -s 2>/dev/null || printf 'unknown')" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

collect_repo_files() {
  if git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    {
      git -C "${REPO_ROOT}" ls-files
      git -C "${REPO_ROOT}" ls-files --others --exclude-standard
    } | awk 'NF && !seen[$0]++' | sort
  else
    (
      cd "${REPO_ROOT}"
      find . \
        \( -path './.git' -o -path './target' -o -path '*/target' -o -path '*/node_modules' -o -path '*/dist' \) -prune \
        -o -type f -print | sed 's|^\./||' | sort
    )
  fi
}

is_linux_or_text_file() {
  local rel="$1"
  local base="${rel##*/}"
  case "${base}" in
    Dockerfile|Dockerfile.*|.dockerignore|.gitattributes|.editorconfig|.gitignore|.env.example|*.env.example|LICENSE)
      return 0
      ;;
  esac
  case "${rel}" in
    *.sh|*.bash|*.service|*.timer|*.socket|*.conf|*.dockerfile|*.yml|*.yaml|*.properties|*.xml|*.json|*.md|*.java|*.ts|*.mts|*.js|*.mjs|*.vue|*.html|*.css)
      return 0
      ;;
  esac
  return 1
}

check_crlf() {
  local list_file="$1"
  local hits=""
  local hit=""
  local bad=0

  if [[ ! -s "${list_file}" ]]; then
    log_info "无受控文本文件，跳过 CRLF 检查"
    return 0
  fi

  hits="$(
    tr '\n' '\0' < "${list_file}" | xargs -0 awk '
      index($0, "\r") > 0 {
        if (!bad_file[FILENAME]++) {
          print FILENAME
        }
      }
    ' || true
  )"

  while IFS= read -r hit; do
    [[ -n "${hit}" ]] || continue
    log_fail "检测到 CRLF（\\r）行尾：${hit#"${REPO_ROOT}/"}"
    bad=$((bad + 1))
  done <<< "${hits}"

  if [[ "${bad}" -eq 0 ]]; then
    log_pass "CRLF 行尾检查通过（全部受控文本与 Linux 文件均为 LF）"
  fi
}

check_sh_executable() {
  local files=("$@")
  local rel=""
  local abs=""
  local is_win=0
  local sh_count=0
  local bad=0
  local line=""
  local mode=""
  local tracked_path=""
  local tracked_modes=""

  if is_windows_env; then
    is_win=1
  fi

  if git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    tracked_modes="$(git -C "${REPO_ROOT}" ls-files --stage -- '*.sh' || true)"
  fi

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    mode="${line%% *}"
    tracked_path="${line#*$'\t'}"
    if [[ -f "${REPO_ROOT}/${tracked_path}" && "${mode}" != "100755" ]]; then
      log_fail "Git 索引中脚本权限非 100755（当前 ${mode}）：${tracked_path}"
      bad=$((bad + 1))
    fi
  done <<< "${tracked_modes}"

  for rel in "${files[@]}"; do
    [[ "${rel}" == *.sh ]] || continue
    abs="${REPO_ROOT}/${rel}"
    [[ -f "${abs}" ]] || continue
    sh_count=$((sh_count + 1))

    if [[ "${is_win}" -eq 0 && ! -x "${abs}" ]]; then
      log_fail "文件系统缺少可执行权限位：${rel}"
      bad=$((bad + 1))
    fi
  done

  if [[ "${sh_count}" -eq 0 ]]; then
    log_info "未发现 *.sh 脚本，跳过权限检查"
  elif [[ "${bad}" -eq 0 ]]; then
    log_pass "脚本可执行权限检查通过（共 ${sh_count} 个 *.sh 文件）"
  fi
}

detect_python() {
  local cand=""
  for cand in python3 python; do
    if command -v "${cand}" >/dev/null 2>&1 && "${cand}" -c "import sys" >/dev/null 2>&1; then
      printf '%s\n' "${cand}"
      return 0
    fi
  done
  return 1
}

check_markdown_paths_and_links() {
  local md_list_file="$1"
  local md_count=0
  local bad=0
  local py_cmd=""
  local hits=""
  local hit=""

  md_count="$(wc -l < "${md_list_file}" | tr -d '[:space:]')"
  if [[ "${md_count}" -eq 0 ]]; then
    log_info "未发现 Markdown 文档，跳过文档路径与链接检查"
    return 0
  fi

  hits="$(tr '\n' '\0' < "${md_list_file}" | xargs -0 grep -nF -e 'file:///' || true)"
  if [[ -n "${hits}" ]]; then
    while IFS= read -r hit; do
      [[ -n "${hit}" ]] && log_fail "文档包含禁止的 file:/// 协议路径：${hit#"${REPO_ROOT}/"}"
    done <<< "${hits}"
    bad=$((bad + 1))
  fi

  hits="$(tr '\n' '\0' < "${md_list_file}" | xargs -0 grep -nE -e '(^|[^A-Za-z0-9_/:])[A-Za-z]:[/\\]' || true)"
  if [[ -n "${hits}" ]]; then
    while IFS= read -r hit; do
      [[ -n "${hit}" ]] && log_fail "文档包含禁止的本地盘符绝对路径：${hit#"${REPO_ROOT}/"}"
    done <<< "${hits}"
    bad=$((bad + 1))
  fi

  hits="$(tr '\n' '\0' < "${md_list_file}" | xargs -0 grep -nE -e '(^|[^A-Za-z0-9_])(/Users/|/home/[A-Za-z0-9._-]+/)' || true)"
  if [[ -n "${hits}" ]]; then
    while IFS= read -r hit; do
      [[ -n "${hit}" ]] && log_fail "文档包含禁止的本地用户家目录绝对路径：${hit#"${REPO_ROOT}/"}"
    done <<< "${hits}"
    bad=$((bad + 1))
  fi

  if py_cmd="$(detect_python)"; then
    local link_output=""
    if ! link_output="$(
      REPO_ROOT="${REPO_ROOT}" MD_LIST_FILE="${md_list_file}" "${py_cmd}" - <<'PYEOF' 2>&1
import os
import re
import sys

root = os.path.abspath(os.environ["REPO_ROOT"])
list_file = os.environ["MD_LIST_FILE"]
link_re = re.compile(r"\[[^\]]+\]\(([^)]+)\)")
broken = []

with open(list_file, "r", encoding="utf-8") as lf:
    md_paths = [line.rstrip("\n") for line in lf if line.strip()]

for abs_path in md_paths:
    if not os.path.isfile(abs_path):
        continue
    rel = os.path.relpath(abs_path, root)
    base_dir = os.path.dirname(abs_path)
    in_code = False
    with open(abs_path, "r", encoding="utf-8", errors="replace") as fh:
        for line_no, line in enumerate(fh, 1):
            stripped = line.strip()
            if stripped.startswith("```"):
                in_code = not in_code
                continue
            if in_code:
                continue
            for match in link_re.finditer(line):
                target = match.group(1).strip()
                if target.startswith(("http://", "https://", "mailto:", "#")):
                    continue
                target_rel = target.split("#", 1)[0].strip()
                if not target_rel:
                    continue
                resolved = os.path.abspath(os.path.join(base_dir, target_rel))
                if not os.path.exists(resolved):
                    broken.append(f"{rel}:{line_no} -> {target}")

if broken:
    for item in broken:
        print(item)
    sys.exit(1)
PYEOF
    )"; then
      if [[ -z "${link_output}" ]]; then
        log_fail "Markdown 站内相对链接校验脚本异常退出"
      else
        while IFS= read -r item; do
          [[ -n "${item}" ]] && log_fail "Markdown 站内相对链接不存在：${item}"
        done <<< "${link_output}"
      fi
      bad=$((bad + 1))
    fi
  fi

  if [[ "${bad}" -eq 0 ]]; then
    log_pass "Markdown 路径安全与相对链接检查通过（共 ${md_count} 篇文档）"
  fi
}

check_secrets() {
  local list_file="$1"
  local pk_begin="-----BEGIN "
  local pk_end="PRIVATE KEY-----"
  local hits=""
  local hit=""
  local bad=0

  if [[ ! -s "${list_file}" ]]; then
    return 0
  fi

  hits="$(tr '\n' '\0' < "${list_file}" | xargs -0 grep -nE -e "${pk_begin}(RSA |EC |DSA |OPENSSH |PGP )?${pk_end}" || true)"
  if [[ -n "${hits}" ]]; then
    while IFS= read -r hit; do
      [[ -n "${hit}" ]] && log_fail "疑似包含明文私钥：${hit#"${REPO_ROOT}/"}"
    done <<< "${hits}"
    bad=$((bad + 1))
  fi

  hits="$(tr '\n' '\0' < "${list_file}" | xargs -0 grep -nE -e '(ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|xox[baprs]-[0-9A-Za-z-]{10,})' || true)"
  if [[ -n "${hits}" ]]; then
    while IFS= read -r hit; do
      [[ -n "${hit}" ]] && log_fail "疑似包含第三方平台密钥或访问令牌：${hit#"${REPO_ROOT}/"}"
    done <<< "${hits}"
    bad=$((bad + 1))
  fi

  if [[ "${bad}" -eq 0 ]]; then
    log_pass "明文凭据与私钥扫描通过"
  fi
}

check_avoid_terms() {
  local list_file="$1"
  local avoid_regex=""
  local hits=""
  local hit=""
  local bad=0

  if [[ ! -s "${list_file}" ]]; then
    return 0
  fi

  # 使用拼接方式组装禁用词正则，防止当前脚本文件命中自检
  avoid_regex="("
  avoid_regex+="工""业级|"
  avoid_regex+="重""装级|"
  avoid_regex+="高""配版|"
  avoid_regex+="快速""使用级|"
  avoid_regex+="Demo""级|"
  avoid_regex+="Demo ""级|"
  avoid_regex+="正""式级|"
  avoid_regex+="线""上版|"
  avoid_regex+="全家桶""编排|"
  avoid_regex+="全栈""一体包|"
  avoid_regex+="裸机""脚本|"
  avoid_regex+="前端 ""systemd 服务|"
  avoid_regex+="分环境""打包|"
  avoid_regex+="一环境""一镜像|"
  avoid_regex+="Overlay ""继承层|"
  avoid_regex+="差量补丁""模板"
  avoid_regex+=")"

  hits="$(
    tr '\n' '\0' < "${list_file}" | xargs -0 grep -nE "${avoid_regex}" | grep -v '_Avoid_' || true
  )"

  if [[ -n "${hits}" ]]; then
    while IFS= read -r hit; do
      [[ -n "${hit}" ]] || continue
      log_fail "命中 _Avoid_ 禁用词：${hit#"${REPO_ROOT}/"}"
      bad=$((bad + 1))
    done <<< "${hits}"
  fi

  if [[ "${bad}" -eq 0 ]]; then
    log_pass "领域术语禁用词扫描通过"
  fi
}

main() {
  log_info "开始执行仓库基线检查（根目录：${REPO_ROOT}）"

  local repo_files=()
  local rel=""
  local abs=""

  TEXT_LIST_FILE="$(mktemp)"
  MD_LIST_FILE="$(mktemp)"

  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    repo_files+=("${rel}")
    abs="${REPO_ROOT}/${rel}"
    [[ -f "${abs}" ]] || continue
    if is_linux_or_text_file "${rel}"; then
      printf '%s\n' "${abs}" >> "${TEXT_LIST_FILE}"
    fi
    if [[ "${rel}" == *.md ]]; then
      printf '%s\n' "${abs}" >> "${MD_LIST_FILE}"
    fi
  done < <(collect_repo_files)

  if [[ "${#repo_files[@]}" -eq 0 ]]; then
    log_fail "未找到任何仓库文件：${REPO_ROOT}"
    exit 1
  fi

  check_crlf "${TEXT_LIST_FILE}"
  check_sh_executable "${repo_files[@]}"
  check_markdown_paths_and_links "${MD_LIST_FILE}"
  check_secrets "${TEXT_LIST_FILE}"
  check_avoid_terms "${TEXT_LIST_FILE}"

  if [[ "${FAILURES}" -gt 0 ]]; then
    printf '[ERROR] 仓库基线检查失败（共 %d 项违例）\n' "${FAILURES}" >&2
    exit 1
  fi

  log_info "仓库基线检查全部通过"
}

main "$@"
