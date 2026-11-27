#!/bin/sh
# 生成 Vue 3 运行时配置脚本并启动只读根文件系统兼容的 Nginx 服务。
#
# @author Ateng
# @since 2026-11-27

set -eu

RUNTIME_DIR="${APP_RUNTIME_CONFIG_DIR:-/tmp/app-runtime}"
RUNTIME_FILE="${APP_RUNTIME_CONFIG_FILE:-${RUNTIME_DIR}/config.js}"
NGINX_TEMP_DIR="${NGINX_TEMP_DIR:-/tmp/nginx}"

# 1. 确保运行时配置与 Nginx 全量临时子目录在可写挂载下就绪
mkdir -p "${RUNTIME_DIR}" \
  "${NGINX_TEMP_DIR}/client_temp" \
  "${NGINX_TEMP_DIR}/proxy_temp" \
  "${NGINX_TEMP_DIR}/fastcgi_temp" \
  "${NGINX_TEMP_DIR}/uwsgi_temp" \
  "${NGINX_TEMP_DIR}/scgi_temp"

# 2. 通过 awk ENVIRON 安全读取并转义环境变量，避免 Shell 展开与 XSS 注入风险
LC_ALL=C awk '
function trim(s) {
  gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", s)
  return s
}
function escape_js(s,    i, n, c, out) {
  out = ""
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\")      out = out "\\\\"
    else if (c == "\"") out = out "\\\""
    else if (c == "\n") out = out "\\n"
    else if (c == "\r") out = out "\\r"
    else if (c == "\t") out = out "\\t"
    else if (c == "\b") out = out "\\b"
    else if (c == "\f") out = out "\\f"
    else if (c == "<")  out = out "\\u003c"
    else if (c == ">")  out = out "\\u003e"
    else if (c == "&")  out = out "\\u0026"
    else                out = out c
  }
  return out
}
BEGIN {
  split("APP_TITLE APP_VERSION APP_ENV APP_API_BASE_URL", keys, " ")
  count = 0
  for (i = 1; i <= 4; i++) {
    k = keys[i]
    v = trim(ENVIRON[k])
    if (v != "") {
      count++
      entries[count] = sprintf("  %s: \"%s\"", k, escape_js(v))
    }
  }
  print "// 由容器启动入口在运行时动态生成，禁止浏览器缓存。"
  if (count == 0) {
    print "window.__APP_CONFIG__ = Object.freeze({});"
  } else {
    print "window.__APP_CONFIG__ = Object.freeze({"
    for (i = 1; i <= count; i++) {
      if (i < count) printf "%s,\n", entries[i]
      else printf "%s\n", entries[i]
    }
    print "});"
  }
}
' > "${RUNTIME_FILE}.tmp"

mv "${RUNTIME_FILE}.tmp" "${RUNTIME_FILE}"

# 3. 移交控制权给 Nginx（或调用方传入命令），确保 SIGTERM 可直达 PID 1
if [ "$#" -eq 0 ]; then
  set -- nginx -g "daemon off;"
fi

exec "$@"
