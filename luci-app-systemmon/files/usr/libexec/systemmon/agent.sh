#!/bin/sh
# SSH / Telnet 节点采集
#
# 目标设备不需要安装本插件，只要开着 SSH 或 Telnet，并且是 busybox/Linux shell，
# 就能取到 CPU、内存、温度、PON（若目标有 ponctl 或 opticaltst）。
#
# 采集分三段命令发送，用 @@S1/@@S2/@@MEM/@@TEMP/@@PON/@@INFO/@@END 分段。

sm_agent_l1='echo @@CPU; cat /proc/cpuusage 2>/dev/null; echo @@S1; cat /proc/stat; echo @@S2; [ -r /proc/cpuusage ] || sleep 2; cat /proc/stat; echo @@MEM; head -c 4096 /proc/meminfo'
sm_agent_l2='echo @@TEMP; cat /proc/tempsensor 2>/dev/null; for z in /sys/class/thermal/thermal_zone*; do [ -r "$z/temp" ] && echo "$(cat $z/type 2>/dev/null)|$(cat $z/temp 2>/dev/null)"; done; echo @@PON; { command -v ponctl >/dev/null 2>&1 && d=$(ponctl list 2>/dev/null | sed -n "s/^device=\([^ ]*\).*/\1/p" | head -n 1) && [ -n "$d" ] && ponctl --device "$d" status --json; }; command -v opticaltst >/dev/null 2>&1 && opticaltst -getpara 2>/dev/null; true'
sm_agent_l3='echo @@INFO; echo "H=$(cat /proc/sys/kernel/hostname)"; echo "M=$(cat /tmp/sysinfo/model 2>/dev/null)"; echo "F=$(grep DISTRIB_DESCRIPTION /etc/openwrt_release 2>/dev/null)"; echo "K=$(uname -r)"; echo "A=$(uname -m)"; echo "U=$(cat /proc/uptime)"; echo "L=$(cat /proc/loadavg)"; echo @@END'

# ---------------------------------------------------------------- 采集

sm_agent_ssh_raw() { # host port user pass
	local host="$1" port="$2" user="$3" pass="$4"
	local ask="$SM_TMP/ask.$$" pf="$SM_TMP/pw.$$" script="$SM_TMP/ag.$$.sh" out

	command -v ssh >/dev/null 2>&1 || return 1

	printf '%s\n' "$pass" >"$pf"
	chmod 600 "$pf" 2>/dev/null
	{
		echo '#!/bin/sh'
		echo "cat '$pf'"
	} >"$ask"
	chmod 700 "$ask" 2>/dev/null

	{
		printf '%s\n' "$sm_agent_l1"
		printf '%s\n' "$sm_agent_l2"
		printf '%s\n' "$sm_agent_l3"
	} >"$script"

	_try() {
		DISPLAY=:0 SSH_ASKPASS="$ask" SSH_ASKPASS_REQUIRE=force \
		sm_timeout 15 ssh -T -p "$port" "$@" \
			-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
			-o BatchMode=no -o PreferredAuthentications=password \
			-o PubkeyAuthentication=no -o KbdInteractiveAuthentication=no \
			-o ConnectTimeout=6 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
			-o LogLevel=ERROR \
			"$user@$host" sh <"$script" 2>/dev/null
	}

	out=$(_try)
	case "$out" in
		*@@END*) ;;
		*) out=$(_try -o HostKeyAlgorithms=ssh-rsa) ;;   # 老 dropbear 只认 ssh-rsa
	esac

	rm -f "$ask" "$pf" "$script"
	printf '%s\n' "$out"
}

sm_agent_telnet_raw() { # host port user pass
	local host="$1" port="$2" user="$3" pass="$4"
	local out="$SM_TMP/tn.$$.out" fifo="$SM_TMP/tn.$$.fifo" fin="$SM_TMP/tn.$$.fin"
	local feeder ncpid i

	command -v nc >/dev/null 2>&1 || return 1
	rm -f "$out" "$fifo" "$fin"
	mkfifo "$fifo" || return 1

	# 发送端在后台跑，避免连接失败时阻塞 CGI；采集完等 done 标记再正常 exit
	(
		sm_sleep 1
		printf '%s\r\n' "$user"
		sm_sleep 1
		printf '%s\r\n' "$pass"
		sm_sleep 2
		printf 'stty -echo 2>/dev/null\r\n'
		sm_sleep 1
		printf '%s\r\n%s\r\n%s\r\n' "$sm_agent_l1" "$sm_agent_l2" "$sm_agent_l3"
		i=0
		while [ ! -f "$fin" ] && [ "$i" -lt 25 ]; do
			sm_sleep 1
			i=$((i + 1))
		done
		printf 'exit\r\n'
		sm_sleep 1
	) >"$fifo" &
	feeder=$!

	nc "$host" "$port" <"$fifo" >"$out" 2>/dev/null &
	ncpid=$!

	i=0
	while [ "$i" -lt 12 ]; do
		grep -q '@@END' "$out" 2>/dev/null && break
		sm_sleep 1
		i=$((i + 1))
	done

	: >"$fin"
	sm_sleep 2
	kill "$feeder" "$ncpid" 2>/dev/null
	wait "$ncpid" 2>/dev/null
	cat "$out"
	rm -f "$fifo" "$out" "$fin"
}

# ---------------------------------------------------------------- 解析

sm_agent_kv() { # 键 原文（去掉首尾空白）
	printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -n 1 |
		sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

sm_agent_parse() { # 原始输出 [地址] → status JSON
	local raw="$1"
	local ip="${2:-}"
	local hostname model firmware kernel arch up load cpu cores
	local cpu_json mem_json temps_json pon_json

	hostname=$(sm_agent_kv H "$raw")
	model=$(sm_agent_kv M "$raw" | tr -d "'\"")
	firmware=$(sm_agent_kv F "$raw" | sed "s/^DISTRIB_DESCRIPTION=//; s/^['\"]//; s/['\"]$//")
	kernel=$(sm_agent_kv K "$raw")
	arch=$(sm_agent_kv A "$raw")
	up=$(sm_agent_kv U "$raw" | awk '{ printf "%d", $1 }')
	load=$(sm_agent_kv L "$raw")

	cpu_json=$(printf '%s\n' "$raw" | awk '
		index($0, "@@CPU") { sec = "cu"; next }
		index($0, "@@S1") { sec = "s1"; next }
		index($0, "@@S2") { sec = "s2"; next }
		index($0, "@@") { sec = ""; next }
		sec == "cu" && /Usage:/ {
			v = $0
			sub(/.*Usage:[ \t]*/, "", v)
			sub(/%.*/, "", v)
			n++; cn[n] = n - 1; cv[n] = v + 0; sum += v + 0
			havecu = 1
			next
		}
		sec != "" && !havecu && $1 ~ /^cpu/ {
			k = $1; t = 0
			for (i = 2; i <= NF; i++) t += $i
			if (sec == "s1") {
				pt[k] = t; pi[k] = $5 + $6; pu[k] = $2 + $3; ps[k] = $4 + $7 + $8
				next
			}
			dt = t - pt[k]; di = ($5 + $6) - pi[k]; du = ($2 + $3) - pu[k]; ds = ($4 + $7 + $8) - ps[k]
			if (dt <= 0) { u = 0; uu = 0; us = 0; ui = 0 }
			else { u = 100*(dt-di)/dt; uu = 100*du/dt; us = 100*ds/dt; ui = 100*di/dt }
			if (u < 0) u = 0
			if (k == "cpu") { tu = u; tuu = uu; tus = us; tui = ui }
			else { n++; cn[n] = substr(k, 4) + 0; cv[n] = u }
		}
		END {
			if (havecu && n > 0) {
				tu = sum / n; tuu = tu; tus = 0; tui = 100 - tu
				if (tui < 0) tui = 0
			}
			printf "{\"usage\":%.1f,\"user\":%.1f,\"system\":%.1f,\"idle\":%.1f,\"source\":\"%s\",\"cores\":[", tu, tuu, tus, tui, (havecu ? "cpuusage" : "proc")
			for (i = 1; i <= n; i++) printf "%s{\"id\":%d,\"usage\":%.1f}", (i > 1 ? "," : ""), cn[i], cv[i]
			printf "]}"
		}')

	cores=$(printf '%s' "$cpu_json" | grep -o '"id":' | wc -l | tr -d ' ')

	mem_json=$(printf '%s\n' "$raw" | awk '
		/^MemTotal:/ { t = $2 }
		/^MemFree:/ { f = $2 }
		/^MemAvailable:/ { a = $2 }
		/^Buffers:/ { b = $2 }
		/^Cached:/ { c = $2 }
		/^SwapTotal:/ { st = $2 }
		/^SwapFree:/ { sf = $2 }
		END {
			if (a <= 0) a = f + b + c
			used = t - a; if (used < 0) used = 0
			up = (t > 0) ? used * 100 / t : 0
			su = st - sf; if (su < 0) su = 0
			printf "{\"total\":%d,\"free\":%d,\"available\":%d,\"used\":%d,\"buffers\":%d,\"cached\":%d,\"usage\":%.1f,\"swap_total\":%d,\"swap_used\":%d}", t, f, a, used, b, c, up, st, su
		}')

	temps_json=$(printf '%s\n' "$raw" | awk '
		function esc(s) { gsub(/["\\]/, "", s); return s }
		BEGIN { printf "[" }
		index($0, "@@TEMP") { sec = 1; next }
		index($0, "@@") { sec = 0 }
		sec == 1 && /temper value:/ {
			v = $0
			sub(/.*temper value:[ \t]*/, "", v)
			gsub(/[^0-9.-]/, "", v)
			if (v != "") printf "%s{\"name\":\"cpu\",\"value\":%.1f}", (n++ ? "," : ""), v + 0
			next
		}
		sec == 1 && index($0, "|") > 0 {
			split($0, a, "|")
			v = a[2] + 0
			if (v > 1000 || v < -1000) v = v / 1000
			if (v < -50 || v > 150) next
			printf "%s{\"name\":\"%s\",\"value\":%.1f}", (n++ ? "," : ""), esc(a[1]), v
		}
		END { printf "]" }')

	pon_json=$(sm_agent_pon "$raw")

	printf '{"ok":true,"host":{"hostname":"%s","model":"%s","firmware":"%s","kernel":"%s","arch":"%s","uptime":%s,"cpu_model":"","cores":%s,"lan_ip":"%s","load":[%s]},"cpu":%s,"memory":%s,"temperatures":%s,"pon":%s,"net":[]}' \
		"$(sm_jstr "$hostname")" "$(sm_jstr "$model")" "$(sm_jstr "$firmware")" \
		"$(sm_jstr "$kernel")" "$(sm_jstr "$arch")" "$(sm_num "$up" 0)" \
		"$(sm_num "$cores" 0)" "$(sm_jstr "$ip")" "$(sm_agent_loads "$load")" \
		"$cpu_json" "$mem_json" "$temps_json" "$pon_json"
}

sm_agent_loads() { # "1.2 3.4 5.6 1/100 1234" → "1.2,3.4,5.6"
	printf '%s' "$1" | awk '{
		n = split($0, a, " ")
		for (i = 1; i <= 3 && i <= n; i++) {
			v = a[i]
			if (v !~ /^[0-9.]+$/) v = 0
			printf "%s%s", (i > 1 ? "," : ""), v
		}
		if (n < 3) printf ",0,0"
	}'
}

sm_agent_pon() { # 原始输出 → pon JSON
	local block t v tx rx bias text
	block=$(printf '%s\n' "$1" | awk 'index($0, "@@PON") { f = 1; next } index($0, "@@INFO") { f = 0 } f')

	if printf '%s' "$block" | grep -q '"rx_power_dbm"'; then
		t=$(sm_json_num temperature_celsius "$block")
		rx=$(sm_json_num rx_power_dbm "$block")
		tx=$(sm_json_num tx_power_dbm "$block")
		v=$(sm_json_num voltage_volts "$block")
		bias=$(sm_json_num tx_bias_ma "$block")
		text=$(sm_json_str onu_state "$block")
		printf '{"available":true,"source":"ponctl","device":"","state":"%s","state_text":"","lifecycle":"","mode":"","temp":%s,"rx_dbm":%s,"tx_dbm":%s,"voltage":%s,"bias":%s,"optical_signal":null,"onu_id":null,"serial":""}' \
			"$(sm_jstr "$text")" "$(sm_num_or_null "$t")" "$(sm_num_or_null "$rx")" \
			"$(sm_num_or_null "$tx")" "$(sm_num_or_null "$v")" "$(sm_num_or_null "$bias")"
		return
	fi

	if printf '%s' "$block" | grep -q 'optical temp'; then
		t=$(printf '%s\n' "$block" | sed -n 's/.*optical temp=\(-\{0,1\}[0-9][0-9]*\).*/\1/p' | head -n 1)
		v=$(printf '%s\n' "$block" | sed -n 's/.*optical SupplyVoltage=\(-\{0,1\}[0-9][0-9]*\).*/\1/p' | head -n 1)
		tx=$(printf '%s\n' "$block" | sed -n 's/.*optical TXPower=\(-\{0,1\}[0-9][0-9]*\).*/\1/p' | head -n 1)
		rx=$(printf '%s\n' "$block" | sed -n 's/.*optical RXPower=\(-\{0,1\}[0-9][0-9]*\).*/\1/p' | head -n 1)
		bias=$(printf '%s\n' "$block" | sed -n 's/.*optical TXBiasCurrent=\(-\{0,1\}[0-9][0-9]*\).*/\1/p' | head -n 1)

		# SFF-8472 原始值：温度 1/256℃，电压 100µV，光功率 0.1µW，偏置 2µA
		t=$(awk -v x="$t" 'BEGIN { if (x == "") exit; printf "%.1f", x / 256 }')
		v=$(awk -v x="$v" 'BEGIN { if (x == "") exit; printf "%.2f", x / 10000 }')
		tx=$(awk -v x="$tx" 'BEGIN { if (x + 0 <= 0) exit; printf "%.2f", 10 * log(x / 10000) / log(10) }')
		rx=$(awk -v x="$rx" 'BEGIN { if (x + 0 <= 0) exit; printf "%.2f", 10 * log(x / 10000) / log(10) }')
		bias=$(awk -v x="$bias" 'BEGIN { if (x == "") exit; printf "%.2f", x * 2 / 1000 }')

		printf '{"available":true,"source":"opticaltst","device":"","state":"","state_text":"","lifecycle":"","mode":"","temp":%s,"rx_dbm":%s,"tx_dbm":%s,"voltage":%s,"bias":%s,"optical_signal":null,"onu_id":null,"serial":""}' \
			"$(sm_num_or_null "$t")" "$(sm_num_or_null "$rx")" "$(sm_num_or_null "$tx")" \
			"$(sm_num_or_null "$v")" "$(sm_num_or_null "$bias")"
		return
	fi

	printf '{"available":false,"source":"none","error":"该节点未提供 PON 数据"}'
}

# ---------------------------------------------------------------- 对外接口

sm_agent_json() { # section
	local sec="$1" type host port user pass cache key raw status name lock lt i ttl
	local age

	type=$(uci -q get "systemmon.$sec.type" 2>/dev/null)
	[ -n "$type" ] || type=plugin

	if [ "$type" = "plugin" ]; then
		printf '{"ok":false,"error":"插件节点由浏览器直接读取"}'
		return
	fi

	key=$(printf '%s' "$sec" | tr -c 'A-Za-z0-9_' '_')
	cache="$SM_TMP/agent.$key.json"
	lock="$SM_TMP/agent.$key.lock"
	age=$(sm_age "$cache")
	# SSH 一次约 2-3 秒，缓存 20 秒；Telnet 一次约 8 秒，缓存 45 秒
	ttl=45
	[ "$type" = "ssh" ] && ttl=20
	if [ -s "$cache" ] && [ "$age" -ge 0 ] && [ "$age" -le "$ttl" ]; then
		cat "$cache"
		return
	fi

	# 同一节点同时只允许一个采集：老设备（尤其 telnet）很多只允许单会话
	if ! mkdir "$lock" 2>/dev/null; then
		lt=0
		read -r lt <"$lock/ts" 2>/dev/null || lt=0
		case "$lt" in ''|*[!0-9]*) lt=0 ;; esac
		if [ "$lt" -gt 0 ] && [ $((SM_UP - lt)) -gt 60 ]; then
			rm -rf "$lock"           # 上次采集异常退出留下的锁
		fi
		if [ -d "$lock" ]; then
			# 已经有采集在进行：有旧数据就先给旧数据，别再开一个会话
			if [ -s "$cache" ]; then
				cat "$cache"
				return
			fi
			i=0
			while [ -d "$lock" ] && [ "$i" -lt 12 ]; do
				sm_sleep 1
				i=$((i + 1))
			done
			if [ -s "$cache" ]; then
				cat "$cache"
				return
			fi
			printf '{"ok":false,"error":"该节点正在采集，请稍后刷新"}'
			return
		fi
	fi
	printf '%s\n' "$SM_UP" >"$lock/ts" 2>/dev/null
	trap "rm -rf '$lock' 2>/dev/null" EXIT INT TERM

	name=$(uci -q get "systemmon.$sec.name" 2>/dev/null)
	host=$(uci -q get "systemmon.$sec.host" 2>/dev/null)
	port=$(uci -q get "systemmon.$sec.port" 2>/dev/null)
	user=$(uci -q get "systemmon.$sec.user" 2>/dev/null)
	pass=$(uci -q get "systemmon.$sec.password" 2>/dev/null)

	if [ -z "$host" ]; then
		printf '{"ok":false,"error":"节点未配置地址"}'
		return
	fi
	if [ -z "$port" ]; then
		[ "$type" = "ssh" ] && port=22 || port=23
	fi
	[ -n "$user" ] || user=root

	if [ "$type" = "ssh" ]; then
		case "$(ssh -V 2>&1)" in
			*OpenSSH*) ;;
			*)
				printf '{"ok":false,"error":"%s"}' \
					"$(sm_jstr '该节点需要 openssh-client：当前 ssh 不是 OpenSSH，无法免交互输入密码')"
				return
				;;
		esac
		raw=$(sm_agent_ssh_raw "$host" "$port" "$user" "$pass")
	else
		raw=$(sm_agent_telnet_raw "$host" "$port" "$user" "$pass")
	fi

	case "$raw" in
		*@@END*) ;;
		*)
			printf '{"ok":false,"error":"%s 连接失败或未登录成功"}' "$(sm_jstr "$type")"
			return
			;;
	esac

	status=$(sm_agent_parse "$raw" "$host")
	printf '{"ok":true,"type":"%s","section":"%s","name":"%s","ts":%s,"status":%s}' \
		"$(sm_jstr "$type")" "$(sm_jstr "$sec")" "$(sm_jstr "$name")" "$SM_NOW" "$status" >"$cache"
	sm_stamp "$cache"
	cat "$cache"
}
