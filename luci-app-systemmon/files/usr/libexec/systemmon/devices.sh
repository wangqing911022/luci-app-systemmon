#!/bin/sh
# 设备监控与发现
#
#   sm_devices_json  已确认监控的设备：增量探测，每次只探最久没探过的若干台，
#                    把 CPU 开销摊平（不再每次全量 ping）
#   sm_discover_json 扫描局域网在线设备，供网页确认后加入监控

# ---------------------------------------------------------------- 通用探测

sm_probe() { # 地址 类型 端口 超时 → "online|rtt"
	local addr="$1" type="$2" port="$3" to="$4"
	local f="$SM_TMP/ping.$$" line rtt=0

	if [ "$type" = "tcp" ] && [ -n "$port" ] && [ "$port" != "0" ]; then
		if command -v nc >/dev/null 2>&1; then
			if sm_timeout "$to" nc -w "$to" "$addr" "$port" </dev/null >/dev/null 2>&1; then
				echo "1|0"
			else
				echo "0|0"
			fi
			return
		fi
	fi

	ping -c 1 -W "$to" "$addr" >"$f" 2>/dev/null
	if [ $? -eq 0 ]; then
		# 用 shell 内建解析，避免每台设备再 fork 一次 sed/head
		while read -r line; do
			case "$line" in
				*time=*) rtt=${line##*time=}; rtt=${rtt%% *}; break ;;
			esac
		done <"$f"
		echo "1|${rtt:-0}"
	else
		echo "0|0"
	fi
	rm -f "$f"
}

# ---------------------------------------------------------------- 已监控设备
#
# 状态文件（TAB 分隔）：ip name type port src online rtt last_seen probed
#   online 0/1；probed 为单调时钟秒数，0 表示还没探过

sm_devices_json() {
	local list="$SM_TMP/dev.list" state="$SM_TMP/devices.state"
	local due="$SM_TMP/dev.due" res="$SM_TMP/dev.res"
	local max timeout interval refresh n batch i ip type port on rtt sum psum lt
	local sec name addr

	max=$(sm_clean_uint "$(sm_cfg max_devices 32)" 1 256 32)
	timeout=$(sm_clean_uint "$(sm_cfg ping_timeout 1)" 1 10 1)
	interval=$(sm_clean_uint "$(sm_cfg device_interval 30)" 1 3600 30)
	refresh=$(sm_clean_uint "$(sm_cfg refresh 3)" 1 60 3)

	# 设备列表只在配置变化时重建（每次请求十几次 uci get 太贵）
	sum=$(md5sum /etc/config/systemmon 2>/dev/null | cut -d' ' -f1)
	[ -n "$sum" ] || sum=none
	psum=""
	[ -s "$list.sum" ] && read -r psum <"$list.sum"

	if [ "$sum" != "$psum" ] || [ ! -s "$list" ]; then
		: >"$list"
		for sec in $(sm_device_sections); do
			[ "$(uci -q get "systemmon.$sec.enabled" 2>/dev/null)" = "0" ] && continue
			name=$(uci -q get "systemmon.$sec.name" 2>/dev/null)
			addr=$(uci -q get "systemmon.$sec.address" 2>/dev/null)
			type=$(uci -q get "systemmon.$sec.type" 2>/dev/null)
			port=$(uci -q get "systemmon.$sec.port" 2>/dev/null)
			[ -n "$addr" ] || continue
			addr=$(sm_clean_addr "$addr")
			[ -n "$addr" ] || continue
			case "$type" in tcp) ;; *) type=ping ;; esac
			[ -n "$port" ] || port=0
			[ -n "$name" ] || name="$addr"
			printf '%s|%s|%s|%s|%s\n' "$name" "$addr" "$type" "$port" "manual" >>"$list"
		done
		awk -F'|' '!seen[$2]++' "$list" | head -n "$max" >"$list.tmp" 2>/dev/null
		mv "$list.tmp" "$list"
		printf '%s\n' "$sum" >"$list.sum"
	fi

	if [ ! -s "$list" ]; then
		: >"$state"
		printf '{"ok":true,"ts":%s,"interval":%s,"total":0,"online":0,"devices":[]}' "$SM_NOW" "$interval"
		return
	fi

	n=$(wc -l <"$list")

	# 每次请求探测几台：让每台设备约 interval 秒轮一遍
	batch=$(( (n * refresh + interval - 1) / interval ))
	[ "$batch" -lt 1 ] && batch=1
	[ "$batch" -gt 8 ] && batch=8
	[ -f "$state" ] || batch="$n"        # 首次运行：一次探完

	# 目标列表 + 旧结果 → 新状态（只在配置变化或状态缺失时重建）
	if [ "$sum" != "$psum" ] || [ ! -s "$state" ]; then
	[ -f "$state" ] || : >"$state"
	tr '\t' '|' <"$state" >"$state.pipe" 2>/dev/null
	awk -F'|' -v OFS='\t' '
		FILENAME == ARGV[1] {
			name[$2] = $1; typ[$2] = $3; port[$2] = $4; src[$2] = $5; order[++n] = $2
			next
		}
		{ on[$1] = $6; rt[$1] = $7; seen[$1] = $8; pb[$1] = $9 }
		END {
			for (i = 1; i <= n; i++) {
				ip = order[i]
				printf "%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\n", ip, name[ip], typ[ip], port[ip], src[ip], on[ip] + 0, rt[ip] + 0, seen[ip] + 0, pb[ip] + 0
			}
		}' "$list" "$state.pipe" >"$state.new" 2>/dev/null
	mv "$state.new" "$state"
	rm -f "$state.pipe"
	fi

	# 持锁的请求做一小批探测；并发请求直接返回当前状态
	# 先清理残留锁（没有时间戳或超过 60 秒的）
	if [ -d "$SM_TMP/dev.lock" ]; then
		lt=""
		read -r lt <"$SM_TMP/dev.lock/ts" 2>/dev/null || lt=""
		case "$lt" in
			''|*[!0-9]*) rm -rf "$SM_TMP/dev.lock" ;;
			*) [ $((SM_UP - lt)) -gt 20 ] && rm -rf "$SM_TMP/dev.lock" ;;
		esac
	fi

	if mkdir "$SM_TMP/dev.lock" 2>/dev/null; then
		printf '%s\n' "$SM_UP" >"$SM_TMP/dev.lock/ts" 2>/dev/null
		# 选出最久没探过的 batch 台（在 awk 里排序，避免 sort/head/cut 在 busybox 上的兼容问题）
		awk -F'\t' -v now="$SM_UP" -v iv="$interval" -v max="$batch" '
			$9 == 0 || now - $9 >= iv {
				n++
				k[n] = $9 + 0; a[n] = $1; b[n] = $3; c[n] = $4
			}
			END {
				for (i = 2; i <= n; i++) {
					vk = k[i]; va = a[i]; vb = b[i]; vc = c[i]
					j = i - 1
					while (j >= 1 && k[j] > vk) {
						k[j + 1] = k[j]; a[j + 1] = a[j]; b[j + 1] = b[j]; c[j + 1] = c[j]
						j--
					}
					k[j + 1] = vk; a[j + 1] = va; b[j + 1] = vb; c[j + 1] = vc
				}
				for (i = 1; i <= n && i <= max; i++) printf "%s|%s|%s\n", a[i], b[i], c[i]
			}' "$state" >"$due" 2>/dev/null

		if [ -s "$due" ]; then
			i=0
			while IFS='|' read -r ip type port; do
				sm_probe "$ip" "$type" "$port" "$timeout" >"$SM_TMP/p.$i" &
				i=$((i + 1))
			done <"$due"
			wait

			i=0
			: >"$res"
			while IFS='|' read -r ip type port; do
				on=0; rtt=0
				IFS='|' read -r on rtt <"$SM_TMP/p.$i" 2>/dev/null
				[ -n "$on" ] || on=0
				printf '%s\t%s\t%s\n' "$ip" "$on" "${rtt:-0}" >>"$res"
				i=$((i + 1))
			done <"$due"

			awk -F'\t' -v OFS='\t' -v now="$SM_UP" -v epoch="$SM_NOW" '
				FILENAME == ARGV[1] { on[$1] = $2; rt[$1] = $3; next }
				{
					if ($1 in on) {
						$6 = on[$1]; $7 = rt[$1]; $9 = now
						if (on[$1] == 1) $8 = epoch
					}
					print
				}' "$res" "$state" 2>/dev/null >"$state.new"
			mv "$state.new" "$state"
			rm -f "$SM_TMP"/p.* "$due" "$res" 2>/dev/null
		fi
		rm -rf "$SM_TMP/dev.lock" 2>/dev/null
	fi

	# 输出 JSON（MAC / 接口从 ARP 表补）
	awk -F'\t' -v now="$SM_NOW" -v iv="$interval" '
		function esc(s) { gsub(/["\\]/, "", s); gsub(/[\r\n\t]/, " ", s); return s }
		FILENAME == ARGV[1] {
			split($0, a, /[ \t]+/)
			if (a[1] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && a[4] != "" && a[4] != "00:00:00:00:00:00") {
				mac[a[1]] = a[4]; aif[a[1]] = a[6]
			}
			next
		}
		{
			n++
			buf[n] = sprintf("{\"name\":\"%s\",\"ip\":\"%s\",\"mac\":\"%s\",\"type\":\"%s\",\"port\":%d,\"source\":\"%s\",\"iface\":\"%s\",\"online\":%s,\"rtt\":%.1f,\"last_seen\":%d,\"probed\":%s}",
				esc($2), esc($1), esc(mac[$1]), esc($3), $4 + 0, esc($5), esc(aif[$1]),
				($6 == 1 ? "true" : "false"), $7 + 0, $8 + 0, ($9 > 0 ? "true" : "false"))
			if ($6 == 1) up++
		}
		END {
			printf "{\"ok\":true,\"ts\":%d,\"interval\":%d,\"total\":%d,\"online\":%d,\"devices\":[", now, iv, n, up
			for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? "," : ""), buf[i]
			printf "]}"
		}' /proc/net/arp "$state"
}

# ---------------------------------------------------------------- 局域网发现

# 输出要扫描的网段（CIDR），优先用 systemmon.scan_subnet
sm_scan_subnets() {
	local spec ipaddr mask bits

	spec=$(sm_cfg scan_subnet '')
	if [ -n "$spec" ]; then
		printf '%s\n' "$spec" | tr ',' '\n'
		return
	fi

	if command -v ip >/dev/null 2>&1; then
		ip -4 -o addr show 2>/dev/null | awk '$3 == "inet" && $2 ~ /^br-/ { print $4 }'
		return
	fi

	ipaddr=$(uci -q get network.lan.ipaddr 2>/dev/null)
	ipaddr=${ipaddr%%/*}
	mask=$(uci -q get network.lan.netmask 2>/dev/null)
	if [ -n "$ipaddr" ]; then
		bits=$(sm_mask2bits "$mask")
		printf '%s/%s\n' "$ipaddr" "${bits:-24}"
	fi
}

# 把网段展开成主机地址列表（跳过网络地址与广播地址，去重，限量）
sm_scan_targets() {
	local max

	max=$(sm_clean_uint "$(sm_cfg scan_max 512)" 1 2048 512)
	sm_scan_subnets | awk -v max="$max" '
		function ip2n(s, a) { split(s, a, "."); return ((a[1]*256+a[2])*256+a[3])*256+a[4] }
		function n2ip(n) { return int(n/16777216)%256 "." int(n/65536)%256 "." int(n/256)%256 "." n%256 }
		{
			line = $0
			gsub(/[ \t\r]/, "", line)
			if (line == "") next
			split(line, p, "/")
			if (p[1] !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) next
			bits = (p[2] == "") ? 24 : p[2] + 0
			if (bits < 16) bits = 24
			if (bits > 32) bits = 32
			shift = 32 - bits
			base = int(ip2n(p[1]) / (2 ^ shift)) * (2 ^ shift)
			count = 2 ^ shift
			start = base + 1
			end = base + count - 2
			if (count <= 2) { start = base; end = base + count - 1 }
			for (n = start; n <= end; n++) {
				if (total >= max) exit
				ip = n2ip(n)
				if (ip in seen) continue
				seen[ip] = 1
				print ip
				total++
			}
		}'
}

# 并发 ping 扫描，存活主机写入 scan.alive（"ip rtt"）
sm_scan_run() {
	local alive="$SM_TMP/scan.alive" targets="$SM_TMP/scan.targets"
	local i=0 ip out rtt

	: >"$alive"
	sm_scan_targets >"$targets" 2>/dev/null
	[ -s "$targets" ] || return 0

	while read -r ip; do
		(
			out=$(ping -c 1 -W 1 "$ip" 2>/dev/null)
			if [ $? -eq 0 ]; then
				rtt=$(printf '%s' "$out" | sed -n 's/.*time=\([0-9][0-9.]*\).*/\1/p' | head -n 1)
				printf '%s %s\n' "$ip" "${rtt:-0}" >>"$alive"
			fi
		) &
		i=$((i + 1))
		[ $((i % 64)) -eq 0 ] && wait
	done <"$targets"
	wait
}

sm_discover_build() {
	local targets=0 self_ip

	rm -f "$SM_TMP/scan.alive"
	sm_scan_run
	[ -s "$SM_TMP/scan.targets" ] && targets=$(wc -l <"$SM_TMP/scan.targets")
	self_ip=$(sm_lan_ip)

	awk -v now="$SM_NOW" -v targets="$targets" -v self="$self_ip" \
		-v useArp="$(sm_bool discover_arp 1)" -v useLeases="$(sm_bool discover_leases 1)" '
		function esc(s) { gsub(/["\\]/, "", s); gsub(/[\r\n\t]/, " ", s); return s }
		FILENAME == ARGV[1] {   # 存活主机：ip rtt
			if ($1 != "") { alive[$1] = 1; rtt[$1] = $2 + 0; cand[$1] = 1 }
			next
		}
		FILENAME == ARGV[2] {   # /proc/net/arp
			if ($1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $4 != "" && $4 != "00:00:00:00:00:00") {
				mac[$1] = $4
				if (useArp == 1) cand[$1] = 1
			}
			next
		}
		FILENAME == ARGV[3] {   # /tmp/dhcp.leases
			if (useLeases == 1 && NF >= 4 && $3 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
				if ($4 != "*" && $4 != "") lname[$3] = $4
				if ($2 != "") lmac[$3] = $2
			}
			next
		}
		END {
			n = 0
			for (ip in cand) {
				if (ip == self || ip == "0.0.0.0") continue
				n++
				list[n] = ip
			}
			# 按 IP 数值排序
			for (i = 2; i <= n; i++) {
				v = list[i]
				j = i - 1
				while (j >= 1 && ipn(list[j]) > ipn(v)) { list[j + 1] = list[j]; j-- }
				list[j + 1] = v
			}
			printf "{\"ok\":true,\"ts\":%d,\"targets\":%d,\"total\":%d,\"devices\":[", now, targets, n
			for (i = 1; i <= n; i++) {
				ip = list[i]
				name = lname[ip]
				if (name == "") name = ""
				m = mac[ip]
				if (m == "") m = lmac[ip]
				src = (lname[ip] != "") ? "dhcp" : "arp"
				printf "%s{\"ip\":\"%s\",\"name\":\"%s\",\"mac\":\"%s\",\"rtt\":%.1f,\"icmp\":%s,\"source\":\"%s\"}",
					(i > 1 ? "," : ""), esc(ip), esc(name), esc(m),
					(ip in alive) ? rtt[ip] : 0,
					(ip in alive) ? "true" : "false", src
			}
			printf "]}"
		}
		function ipn(s, a) { split(s, a, "."); return ((a[1]*256+a[2])*256+a[3])*256+a[4] }
	' "$SM_TMP/scan.alive" /proc/net/arp /tmp/dhcp.leases >"$SM_TMP/discover.json.new" 2>/dev/null

	[ -s "$SM_TMP/discover.json.new" ] ||
		printf '{"ok":true,"ts":%s,"targets":%s,"total":0,"devices":[]}' "$SM_NOW" "$targets" >"$SM_TMP/discover.json.new"
	mv "$SM_TMP/discover.json.new" "$SM_TMP/discover.json"
	sm_stamp "$SM_TMP/discover.json"
	rm -f "$SM_TMP/scan.alive" "$SM_TMP/scan.targets" 2>/dev/null
}

sm_discover_json() { # $1=1 强制重新扫描
	local cache="$SM_TMP/discover.json" limit age lockage lt

	limit=$(sm_clean_uint "$(sm_cfg scan_interval 120)" 10 3600 120)
	age=$(sm_age "$cache")

	if [ "$1" != "1" ] && [ -s "$cache" ] && [ "$age" -ge 0 ] && [ "$age" -le "$limit" ]; then
		cat "$cache"
		return
	fi

	# 扫描锁：避免多个页面同时全网 ping（时间戳用单调时钟）
	if [ -d "$SM_TMP/scan.lock" ]; then
		lt=0
		read -r lt <"$SM_TMP/scan.lock/ts" 2>/dev/null
		case "$lt" in ''|*[!0-9]*) lt=0 ;; esac
		if [ "$lt" -gt 0 ] && [ $((SM_UP - lt)) -gt 60 ]; then
			rm -rf "$SM_TMP/scan.lock"
		fi
	fi

	if mkdir "$SM_TMP/scan.lock" 2>/dev/null; then
		printf '%s\n' "$SM_UP" >"$SM_TMP/scan.lock/ts" 2>/dev/null
		sm_discover_build
		rm -rf "$SM_TMP/scan.lock" 2>/dev/null
	elif [ -s "$cache" ]; then
		cat "$cache"
		return
	else
		printf '{"ok":false,"error":"%s"}' "$(sm_jstr '正在扫描，请稍后刷新')"
		return
	fi

	cat "$cache" 2>/dev/null || printf '{"ok":true,"ts":%s,"total":0,"devices":[]}' "$SM_NOW"
}
