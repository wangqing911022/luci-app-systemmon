#!/bin/sh
# systemmon 公共函数库：配置读取、JSON 转义、认证、访问控制、表单解析

SM_TMP=/tmp/systemmon
SM_UCI=systemmon
SM_NOW=$(date +%s)
# 单调时钟（秒）：缓存新鲜度用它，避免 NTP 校时把时间改回去导致缓存判断错乱
SM_UP=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)
case "$SM_UP" in ''|*[!0-9]*) SM_UP=0 ;; esac

mkdir -p "$SM_TMP" 2>/dev/null

# ---------------------------------------------------------------- 配置

sm_cfg() { # 键 默认值
	local v
	v=$(uci -q get "$SM_UCI.main.$1" 2>/dev/null)
	[ -n "$v" ] || v="$2"
	printf '%s' "$v"
}

sm_pon_cfg() { # 键 默认值
	local v
	v=$(uci -q get "$SM_UCI.pon.$1" 2>/dev/null)
	[ -n "$v" ] || v="$2"
	printf '%s' "$v"
}

sm_bool() { # 键 默认值
	case "$(sm_cfg "$1" "$2")" in
		1|on|true|yes|enabled) echo 1 ;;
		*) echo 0 ;;
	esac
}

# ---------------------------------------------------------------- 输出

sm_jstr() { # 转义为 JSON 字符串内容（不含两侧引号）
	printf '%s' "$1" | awk 'BEGIN{ORS=""} {
		gsub(/\\/, "\\\\")
		gsub(/"/, "\\\"")
		gsub(/\t/, " ")
		gsub(/\r/, " ")
		print
	}'
}

sm_num() { # 数字 默认值，非法值回退默认值
	printf '%s' "${1:-}" | awk -v def="${2:-0}" '
		{ s = $0; gsub(/^[ \t]+|[ \t]+$/, "", s)
		  if (s ~ /^-?[0-9]+(\.[0-9]+)?$/) printf "%s", s; else printf "%s", def }
		END { if (NR == 0) printf "%s", def }'
}

sm_num_or_null() { # 数字，非法或空输出 JSON null
	printf '%s' "${1:-}" | awk '
		{ s = $0; gsub(/^[ \t]+|[ \t]+$/, "", s)
		  if (s ~ /^-?[0-9]+(\.[0-9]+)?$/) printf "%s", s; else printf "null" }
		END { if (NR == 0) printf "null" }'
}

sm_json_num() { # 键 单行 JSON → 数字
	printf '%s' "${2:-}" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*-\{0,1\}[0-9][0-9.]*" 2>/dev/null |
		head -n 1 | sed 's/.*:[[:space:]]*//'
}

sm_json_str() { # 键 单行 JSON → 字符串
	printf '%s' "${2:-}" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null |
		head -n 1 | sed 's/^[^:]*:[[:space:]]*"//; s/"$//'
}

sm_json_bool() { # 键 单行 JSON → true/false/空
	printf '%s' "${2:-}" | tr -d ' \t' | grep -o "\"$1\":\(true\|false\)" 2>/dev/null |
		head -n 1 | sed 's/.*://'
}

sm_headers() { # content-type [cors]
	printf 'Content-Type: %s\r\n' "${1:-application/json; charset=utf-8}"
	printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
	printf 'Pragma: no-cache\r\n'
	printf 'X-Content-Type-Options: nosniff\r\n'
	if [ "$2" = "cors" ]; then
		printf 'Access-Control-Allow-Origin: *\r\n'
		printf 'Access-Control-Allow-Methods: GET, OPTIONS\r\n'
		printf 'Access-Control-Allow-Headers: Authorization\r\n'
	fi
	printf '\r\n'
}

sm_fail() { # 状态码文本 消息
	printf 'Status: %s\r\n' "$1"
	sm_headers 'application/json; charset=utf-8'
	printf '{"ok":false,"error":"%s"}\n' "$(sm_jstr "$2")"
	exit 0
}

# ---------------------------------------------------------------- 认证与访问控制

sm_b64() {
	local tool
	if command -v base64 >/dev/null 2>&1; then
		tool="base64"
	elif [ -x /usr/bin/openssl ]; then
		tool="openssl base64"
	elif busybox --list 2>/dev/null | grep -qx base64; then
		tool="busybox base64"
	else
		return 1
	fi
	$tool
}

sm_in_cidr() { # IP CIDR列表
	awk -v ip="$1" -v list="$2" '
		function ip2n(s,  a) {
			split(s, a, ".")
			return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4]
		}
		BEGIN {
			n = ip2n(ip)
			cnt = split(list, arr, ",")
			for (i = 1; i <= cnt; i++) {
				x = arr[i]
				gsub(/[ \t]/, "", x)
				if (x == "") continue
				split(x, p, "/")
				base = ip2n(p[1])
				bits = (p[2] == "") ? 32 : p[2] + 0
				if (bits < 0) bits = 0
				if (bits > 32) bits = 32
				shift = 32 - bits
				if (shift == 0 || int(n / (2 ^ shift)) == int(base / (2 ^ shift))) exit 0
			}
			exit 1
		}'
}

sm_guard() {
	local ip="${REMOTE_ADDR:-}"

	if [ -n "$ip" ]; then
		if ! sm_in_cidr "$ip" "$(sm_cfg allow_cidr '0.0.0.0/0')"; then
			printf 'Status: 403 Forbidden\r\n'
			sm_headers 'text/plain; charset=utf-8'
			printf '禁止访问\n'
			exit 0
		fi
	fi

	local user pass want got
	user=$(sm_cfg auth_user '')
	[ -n "$user" ] || return 0
	pass=$(sm_cfg auth_password '')
	want=$(printf '%s' "$user:$pass" | sm_b64 2>/dev/null | tr -d '\r\n')
	[ -n "$want" ] || sm_fail '500 Internal Server Error' '缺少 base64 工具，无法校验认证'

	got=''
	case "${HTTP_AUTHORIZATION:-}" in
		Basic\ *) got="${HTTP_AUTHORIZATION#Basic }" ;;
		basic\ *) got="${HTTP_AUTHORIZATION#basic }" ;;
	esac
	got=$(printf '%s' "$got" | tr -d '\r\n')
	[ "$got" = "$want" ] && return 0

	printf 'Status: 401 Unauthorized\r\n'
	printf 'WWW-Authenticate: Basic realm="systemmon"\r\n'
	sm_headers 'text/plain; charset=utf-8'
	printf '需要登录\n'
	exit 0
}

# ---------------------------------------------------------------- 杂项

# 缓存年龄：与缓存文件同名的 .ts 文件里记录写入时刻（单调时钟，不依赖 stat）
sm_age() { # 缓存文件 → 秒数（文件不存在返回 99999）
	local ts=0
	read -r ts <"$1.ts" 2>/dev/null || ts=0
	case "$ts" in
		''|*[!0-9]*) printf '99999' ;;
		*) printf '%s' $(( SM_UP - ts )) ;;
	esac
}

sm_stamp() { # 缓存文件
	printf '%s\n' "$SM_UP" >"$1.ts" 2>/dev/null
}

# 修改类请求的同源校验（uhttpd 不会透传自定义请求头，只能依赖 Origin/Referer）
# 浏览器发起的跨站 POST 一定带 Origin，据此即可拦住 CSRF。
sm_csrf_ok() {
	local host="${HTTP_HOST:-}" origin="${HTTP_ORIGIN:-}" ref="${HTTP_REFERER:-}"

	if [ -n "$origin" ]; then
		case "$origin" in
			"http://$host"|"https://$host") return 0 ;;
			*) return 1 ;;
		esac
	fi
	if [ -n "$ref" ]; then
		case "$ref" in
			"http://$host"/*|"https://$host"/*) return 0 ;;
			*) return 1 ;;
		esac
	fi
	# 没有 Origin/Referer 的是命令行等非浏览器客户端，不存在 CSRF 场景
	return 0
}

sm_sleep() {
	sleep "$1" 2>/dev/null || sleep 1
}

sm_timeout() { # 秒 命令...
	local secs="$1"
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout "$secs" "$@"
	else
		"$@"
	fi
}

sm_body() { # 读取 POST 表单（限制 4KB）
	[ "${REQUEST_METHOD:-GET}" = "POST" ] || return 0
	local len="${CONTENT_LENGTH:-0}"
	case "$len" in ''|*[!0-9]*) len=0 ;; esac
	[ "$len" -gt 0 ] && [ "$len" -le 4096 ] || return 0
	dd bs=1 count="$len" 2>/dev/null
}

sm_urldecode() {
	printf '%s' "$1" | awk '
		function hv(c) { return index("0123456789abcdef", tolower(c)) - 1 }
		{
			s = $0
			gsub(/\+/, " ", s)
			out = ""
			while (match(s, /%[0-9A-Fa-f][0-9A-Fa-f]/)) {
				h = substr(s, RSTART + 1, 2)
				out = out substr(s, 1, RSTART - 1) sprintf("%c", hv(substr(h,1,1)) * 16 + hv(substr(h,2,1)))
				s = substr(s, RSTART + 3)
			}
			printf "%s%s", out, s
		}'
}

sm_form() { # 字段名（需先给 SM_BODY 赋值）
	printf '%s' "${SM_BODY:-}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1
}

sm_form_val() { # 字段名
	SM_V=$(sm_urldecode "$(sm_form "$1")")
	printf '%s' "$SM_V"
}

sm_clean_addr() {
	printf '%s' "$1" | tr -d ' \t\r\n' | sed 's/[^0-9A-Za-z.:_-]//g' | head -c 128
}

sm_clean_name() {
	printf '%s' "$1" | sed 's/["\\]//g; s/[[:cntrl:]]//g' | head -c 60
}

sm_clean_uint() { # 值 最小 最大 默认
	local v="$1"
	case "$v" in ''|*[!0-9]*) v="$4" ;; esac
	[ "$v" -lt "$2" ] && v="$2"
	[ "$v" -gt "$3" ] && v="$3"
	printf '%s' "$v"
}

# 返回当前 LAN 的 IPv4 地址（用于页面展示与自动发现时排除本机）
sm_lan_ip() {
	local ip
	ip=$(uci -q get network.lan.ipaddr 2>/dev/null)
	ip=${ip%%/*}
	if [ -z "$ip" ]; then
		ip=$(ip -4 -o addr show br-lan 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1)
	fi
	[ -n "$ip" ] || ip=$(hostname -i 2>/dev/null | awk '{print $1}')
	printf '%s' "${ip:-127.0.0.1}"
}

# 列出所有 systemmon 的 device 段名（含 @device[N] 形式）
sm_device_sections() {
	uci -q show systemmon 2>/dev/null | sed -n 's/^systemmon\.\(.*\)=device$/\1/p'
}

# 列出所有远程节点段名
sm_node_sections() {
	uci -q show systemmon 2>/dev/null | sed -n 's/^systemmon\.\(.*\)=node$/\1/p'
}

# 点分十进制掩码 → 前缀位数
sm_mask2bits() {
	awk -v m="${1:-255.255.255.0}" 'BEGIN {
		n = 0; cnt = split(m, a, ".")
		for (i = 1; i <= cnt; i++) { v = a[i] + 0; while (v > 0) { n += v % 2; v = int(v / 2) } }
		print n
	}'
}
