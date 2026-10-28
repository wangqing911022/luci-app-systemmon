#!/bin/sh
# 本机指标：CPU、内存、温度、网络速率、系统信息
# 所有函数只输出 JSON 片段，不带换行

# 静态信息（主机名/型号/固件/内核/架构/核心数/地址）很少变，缓存 5 分钟，只留 uptime/负载每次读
sm_host_static() {
	local cache="$SM_TMP/host.static" age
	local hostname model fw kernel arch ip cpu_model cores

	age=$(sm_age "$cache")
	if [ -s "$cache" ] && [ "$age" -ge 0 ] && [ "$age" -le 300 ]; then
		cat "$cache"
		return
	fi

	hostname=$(cat /proc/sys/kernel/hostname 2>/dev/null)
	[ -n "$hostname" ] || hostname=$(uci -q get system.@system[0].hostname 2>/dev/null)
	model=$(cat /tmp/sysinfo/model 2>/dev/null)
	[ -n "$model" ] || model=$(jsonfilter -e '@.model.name' </etc/board.json 2>/dev/null)
	[ -n "$model" ] || model=$(uci -q get system.@system[0].description 2>/dev/null)
	fw=$(sed -n "s/^DISTRIB_DESCRIPTION='\(.*\)'$/\1/p" /etc/openwrt_release 2>/dev/null | head -n 1)
	[ -n "$fw" ] || fw=$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release 2>/dev/null | head -n 1)
	kernel=$(uname -r 2>/dev/null)
	arch=$(uname -m 2>/dev/null)
	cpu_model=$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n 1)
	[ -n "$cpu_model" ] || cpu_model=$(sed -n 's/^Processor[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n 1)
	[ -n "$cpu_model" ] || cpu_model=$(sed -n 's/^Hardware[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n 1)
	cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
	ip=$(sm_lan_ip)

	printf '"hostname":"%s","model":"%s","firmware":"%s","kernel":"%s","arch":"%s","cpu_model":"%s","cores":%s,"lan_ip":"%s"' \
		"$(sm_jstr "$hostname")" "$(sm_jstr "$model")" "$(sm_jstr "$fw")" \
		"$(sm_jstr "$kernel")" "$(sm_jstr "$arch")" "$(sm_jstr "$cpu_model")" \
		"$(sm_num "$cores" 1)" "$(sm_jstr "$ip")" >"$cache"
	sm_stamp "$cache"
	cat "$cache"
}

sm_host_json() {
	local up load l1 l2 l3

	up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)
	load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
	l1=$(printf '%s' "$load" | cut -d' ' -f1)
	l2=$(printf '%s' "$load" | cut -d' ' -f2)
	l3=$(printf '%s' "$load" | cut -d' ' -f3)

	printf '{%s,"uptime":%s,"load":[%s,%s,%s]}' \
		"$(sm_host_static)" \
		"$(sm_num "$up" 0)" \
		"$(sm_num "$l1" 0)" "$(sm_num "$l2" 0)" "$(sm_num "$l3" 0)"
}

# CPU 使用率：与上一次请求的采样做差；间隔过久时现场采两次
sm_cpu_json() {
	local base="$SM_TMP/cpu.base" res="$SM_TMP/cpu.json"
	local tp="$SM_TMP/cpu.p.$$" tn="$SM_TMP/cpu.n.$$" ts rage

	# 结果缓存 5 秒：多个页面同时刷新时窗口太短，会把每次请求自己的开销算进去
	rage=$(sm_age "$res")
	if [ -s "$res" ] && [ "$rage" -ge 0 ] && [ "$rage" -lt 5 ]; then
		cat "$res"
		return
	fi

	# 上一份基准（第一行是采样时刻），先原子拷贝，避免并发时读到半份数据
	ts=0
	if [ -s "$base" ]; then
		cp "$base" "$tp" 2>/dev/null
		read -r ts <"$tp" 2>/dev/null
	fi
	case "$ts" in ''|*[!0-9]*) ts=0 ;; esac

	{
		printf '%s\n' "$SM_UP"
		grep -E '^cpu' /proc/stat
	} >"$tn" 2>/dev/null

	# 没有基准或太久远：换 0.2 秒窗口现场采两次
	if [ "$ts" -eq 0 ] || [ $((SM_UP - ts)) -gt 30 ]; then
		cp "$tn" "$tp"
		sm_sleep 0.2
		{
			printf '%s\n' "$SM_UP"
			grep -E '^cpu' /proc/stat
		} >"$tn" 2>/dev/null
	fi

	# 两份采样缺任何一份都会算出离谱的值，直接沿用上次结果
	if [ "$(wc -l <"$tp" 2>/dev/null || echo 0)" -lt 2 ] ||
		[ "$(wc -l <"$tn" 2>/dev/null || echo 0)" -lt 2 ]; then
		[ -s "$res" ] && cat "$res" || printf '{"usage":0,"user":0,"system":0,"idle":100,"cores":[]}'
		rm -f "$tp" 2>/dev/null
		return
	fi

	awk '
		BEGIN { printf "{" }
		FILENAME == ARGV[1] {
			if (FNR == 1) next
			k = $1; t = 0
			for (i = 2; i <= NF; i++) t += $i
			pt[k] = t
			pi[k] = $5 + $6
			pu[k] = $2 + $3
			ps[k] = $4 + $7 + $8
			next
		}
		FNR == 1 { next }
		{
			k = $1; t = 0
			for (i = 2; i <= NF; i++) t += $i
			dt = t - pt[k]
			di = ($5 + $6) - pi[k]
			du = ($2 + $3) - pu[k]
			ds = ($4 + $7 + $8) - ps[k]
			if (dt <= 0) { u = 0; uu = 0; us = 0; ui = 0 }
			else {
				u = 100 * (dt - di) / dt
				uu = 100 * du / dt
				us = 100 * ds / dt
				ui = 100 * di / dt
			}
			if (u < 0) u = 0
			if (k == "cpu") { tu = u; tuu = uu; tus = us; tui = ui }
			else { n++; cn[n] = substr(k, 4) + 0; cv[n] = u }
		}
		END {
			printf "\"usage\":%.1f,\"user\":%.1f,\"system\":%.1f,\"idle\":%.1f,\"cores\":[", tu, tuu, tus, tui
			for (i = 1; i <= n; i++)
				printf "%s{\"id\":%d,\"usage\":%.1f}", (i > 1 ? "," : ""), cn[i], cv[i]
			printf "]}"
		}' "$tp" "$tn" >"$res"

	mv "$tn" "$base" 2>/dev/null
	rm -f "$tp" 2>/dev/null
	sm_stamp "$res"
	cat "$res"
}

sm_mem_json() {
	awk '
		/^MemTotal:/ { t = $2 }
		/^MemFree:/ { f = $2 }
		/^MemAvailable:/ { a = $2 }
		/^Buffers:/ { b = $2 }
		/^Cached:/ { c = $2 }
		/^SwapTotal:/ { st = $2 }
		/^SwapFree:/ { sf = $2 }
		END {
			if (a <= 0) a = f + b + c
			used = t - a
			if (used < 0) used = 0
			up = (t > 0) ? used * 100 / t : 0
			su = st - sf
			if (su < 0) su = 0
			printf "{\"total\":%d,\"free\":%d,\"available\":%d,\"used\":%d,\"buffers\":%d,\"cached\":%d,\"usage\":%.1f,\"swap_total\":%d,\"swap_used\":%d}", t, f, a, used, b, c, up, st, su
		}' /proc/meminfo 2>/dev/null
}

sm_temps_raw() { # 输出 name|摄氏度
	local z t type h name f v i=0

	for z in /sys/class/thermal/thermal_zone*; do
		[ -r "$z/temp" ] || continue
		t=$(cat "$z/temp" 2>/dev/null)
		case "$t" in ''|*[!0-9-]*) continue ;; esac
		type=$(cat "$z/type" 2>/dev/null)
		[ -n "$type" ] || type=$(basename "$z")
		if [ "${t#-}" -ge 1000 ] 2>/dev/null; then
			t=$(awk -v v="$t" 'BEGIN { printf "%.1f", v / 1000 }')
		fi
		printf '%s|%s\n' "$type" "$t"
		i=$((i + 1))
		[ "$i" -ge 8 ] && break
	done

	[ "$i" -gt 0 ] && return 0

	# 没有 thermal zone 时退化为 hwmon
	for h in /sys/class/hwmon/hwmon*; do
		[ -r "$h/name" ] || continue
		name=$(cat "$h/name" 2>/dev/null)
		for f in "$h"/temp*_input; do
			[ -r "$f" ] || continue
			v=$(cat "$f" 2>/dev/null)
			case "$v" in ''|*[!0-9-]*) continue ;; esac
			v=$(awk -v x="$v" 'BEGIN { printf "%.1f", x / 1000 }')
			printf '%s|%s\n' "$name" "$v"
			i=$((i + 1))
			[ "$i" -ge 8 ] && break
		done
		[ "$i" -ge 8 ] && break
	done
}

sm_temps_json() {
	sm_temps_raw | sort -u | awk -F'|' '
		BEGIN { printf "[" }
		NF >= 2 {
			name = $1
			gsub(/\\/, "\\\\", name)
			gsub(/"/, "\\\"", name)
			val = $2
			if (val !~ /^-?[0-9]+(\.[0-9]+)?$/) val = 0
			printf "%s{\"name\":\"%s\",\"value\":%s}", (n++ ? "," : ""), name, val
		}
		END { printf "]" }'
}

# 网络接口累计字节与实时速率（B/s）
sm_net_json() {
	local out="$SM_TMP/net.now" prev="$SM_TMP/net.prev"

	{
		echo "$SM_NOW"
		awk -F: '
			/^[ ]*[A-Za-z0-9._-]+:/ {
				iface = $1
				gsub(/^[ \t]+|[ \t]+$/, "", iface)
				if (iface == "lo") next
				rest = $2
				sub(/^[ \t]+/, "", rest)
				split(rest, f, /[ \t]+/)
				printf "%s %s %s\n", iface, f[1] + 0, f[9] + 0
			}' /proc/net/dev 2>/dev/null
	} >"$out.tmp"

	if [ -s "$prev" ]; then
		awk '
			FNR == NR { if (FNR == 1) { pt = $1; next } prx[$1] = $2; ptx[$1] = $3; next }
			FNR == 1 { nt = $1; next }
			{
				iface = $1
				if (iface ~ /^(lo|sit|ip6tnl|gre|tun|tap|veth|dummy|docker|omci|oam)/) next
				dt = nt - pt
				drx = $2 - prx[iface]; if (drx < 0) drx = 0
				dtx = $3 - ptx[iface]; if (dtx < 0) dtx = 0
				rrx = (dt > 0) ? drx / dt : 0
				rtx = (dt > 0) ? dtx / dt : 0
				if (++n > 8) next
				printf "%s{\"name\":\"%s\",\"rx\":%.0f,\"tx\":%.0f,\"rx_rate\":%.0f,\"tx_rate\":%.0f}", (n > 1 ? "," : ""), iface, $2, $3, rrx, rtx
			}' "$prev" "$out.tmp" | awk 'BEGIN { printf "[" } { printf "%s", $0 } END { printf "]" }'
	else
		awk 'FNR == 1 { next } {
				if ($1 ~ /^(lo|sit|ip6tnl|gre|tun|tap|veth|dummy|docker|omci|oam)/) next
				if (++n > 8) next
				printf "%s{\"name\":\"%s\",\"rx\":%.0f,\"tx\":%.0f,\"rx_rate\":0,\"tx_rate\":0}", (n > 1 ? "," : ""), $1, $2, $3
			}' "$out.tmp" | awk 'BEGIN { printf "[" } { printf "%s", $0 } END { printf "]" }'
	fi

	mv "$out.tmp" "$out"
	cp "$out" "$prev" 2>/dev/null
}
