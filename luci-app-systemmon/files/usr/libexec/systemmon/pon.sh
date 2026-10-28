#!/bin/sh
# PON 光模块信息采集
#
# 优先级：
#   1. UCI 自定义命令（systemmon.pon.command）
#   2. airoha-ponctl  status --json（本机固件自带）
#   3. ethtool -m <sfp_iface>  （SFP DDM）
#   4. /sys/class/hwmon 里的 sfp/optic/pon 温度与光功率
#
# 输出 JSON：{available, source, device, state, temp, rx_dbm, tx_dbm, ...}

SM_PON_STATE_TEXT="" # 由 sm_pon_state_text 填充

sm_pon_state_text() {
	case "$1" in
		O1) echo "初始化" ;;
		O2) echo "待机" ;;
		O3) echo "测距" ;;
		O4) echo "请求配置" ;;
		O5) echo "工作正常" ;;
		O6) echo "失步" ;;
		O7) echo "紧急停用" ;;
		''|none|None|null) echo "" ;;
		*) echo "" ;;
	esac
}

sm_pon_lifecycle_text() {
	case "$1" in
		operational|ready|up|online) echo "工作正常" ;;
		wait-optical-signal|wait_optical_signal|no-signal|no_signal) echo "等待光信号" ;;
		stopped|stop) echo "PON 已停止" ;;
		down|idle|offline|disabled) echo "链路未建立" ;;
		*) echo "" ;;
	esac
}

sm_dbm_from_mw() {
	awk -v mw="$1" 'BEGIN {
		if (mw + 0 <= 0) { print ""; exit }
		printf "%.2f", 10 * log(mw) / log(10)
	}'
}

sm_ponctl_path() {
	if [ -x /usr/sbin/ponctl ]; then
		echo /usr/sbin/ponctl
	elif [ -x /usr/bin/ponctl ]; then
		echo /usr/bin/ponctl
	elif command -v ponctl >/dev/null 2>&1; then
		command -v ponctl
	fi
}

# ---------------------------------------------------------------- 各后端

sm_pon_from_command() { # 命令 → 全局变量
	local cmd out k v
	cmd="$1"
	[ -n "$cmd" ] || return 1
	out=$(sm_timeout 5 sh -c "$cmd" 2>/dev/null | head -n 30)
	[ -n "$out" ] || return 1
	while IFS='=' read -r k v; do
		v=$(printf '%s' "$v" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		case "$k" in
			temp|temperature) P_TEMP="$v" ;;
			rx|rx_dbm|rx_power|rxpower) P_RX="$v" ;;
			tx|tx_dbm|tx_power|txpower) P_TX="$v" ;;
			state|status) P_STATE="$v" ;;
			mode) P_MODE="$v" ;;
			serial|sn) P_SERIAL="$v" ;;
			onu_id|onuid) P_ONU="$v" ;;
			device) P_DEV="$v" ;;
		esac
	done <<EOF
$out
EOF
	P_SOURCE="custom"
	return 0
}

sm_pon_from_ponctl() {
	local bin dev json raw
	bin=$(sm_ponctl_path)
	[ -n "$bin" ] || return 1

	dev=$(sm_pon_cfg device '')
	if [ -z "$dev" ]; then
		# 设备名基本不变，记一次省掉重复的 ponctl list
		dev=$(cat "$SM_TMP/pon.dev" 2>/dev/null)
		if [ -z "$dev" ]; then
			raw=$(sm_timeout 5 "$bin" list 2>/dev/null)
			dev=$(printf '%s\n' "$raw" | sed -n 's/^device=\([^ ]*\).*/\1/p' | head -n 1)
			[ -n "$dev" ] && printf '%s\n' "$dev" >"$SM_TMP/pon.dev"
		fi
	fi
	[ -n "$dev" ] || return 1

	json=$(sm_timeout 5 "$bin" --device "$dev" status --json 2>/dev/null)
	[ -n "$json" ] || return 1
	# 只保留单行，便于后续提取
	json=$(printf '%s' "$json" | tr -d '\n\r')

	P_DEV="$dev"
	P_SOURCE="ponctl"
	P_TEMP=$(sm_json_num temperature_celsius "$json")
	P_RX=$(sm_json_num rx_power_dbm "$json")
	P_TX=$(sm_json_num tx_power_dbm "$json")
	P_STATE=$(sm_json_str onu_state "$json")
	[ -n "$P_STATE" ] || P_STATE=$(sm_json_str mpcp_state "$json")
	P_LIFE=$(sm_json_str lifecycle "$json")
	P_MODE=$(sm_json_str active_mode "$json")
	[ -n "$P_MODE" ] || P_MODE=$(sm_json_str configured_mode "$json")
	P_ONU=$(sm_json_num onu_id "$json")
	P_SERIAL=$(sm_json_str serial_number "$json")
	P_VOLT=$(sm_json_num voltage_volts "$json")
	P_BIAS=$(sm_json_num tx_bias_ma "$json")
	P_OPT=$(sm_json_bool optical_signal "$json")

	# frontend.error=true 时读不到光功率，按空值处理
	case "$json" in
		*'"error":true'*) P_RX=""; P_TX=""; P_TEMP="" ;;
	esac

	# 未收到光时 rx/tx 是 -40 之类的占位值，不能当真实读数展示
	if [ "$P_OPT" = "false" ]; then
		P_RX=""
		P_TX=""
		P_STATE=""
	fi
	return 0
}

sm_pon_from_ethtool() {
	local iface out rx tx temp

	iface=$(sm_pon_cfg sfp_iface '')
	[ -n "$iface" ] || return 1
	command -v ethtool >/dev/null 2>&1 || return 1

	out=$(sm_timeout 6 ethtool -m "$iface" 2>/dev/null)
	[ -n "$out" ] || return 1

	temp=$(printf '%s\n' "$out" | sed -n 's/.*[Tt]emperature:[[:space:]]*\(-\{0,1\}[0-9][0-9.]*\)[[:space:]]*degrees C.*/\1/p' | head -n 1)

	rx=$(printf '%s\n' "$out" | sed -n '/[Rr]eceiver signal average optical power/{
		s/.*\/[[:space:]]*\(-\{0,1\}[0-9][0-9.]*\)[[:space:]]*dBm.*/\1/p
	}' | head -n 1)
	if [ -z "$rx" ]; then
		rx=$(printf '%s\n' "$out" | sed -n '/[Rr]eceiver signal average optical power/{
			s/.*:[[:space:]]*\([0-9][0-9.]*\)[[:space:]]*mW.*/\1/p
		}' | head -n 1)
		[ -n "$rx" ] && rx=$(sm_dbm_from_mw "$rx")
	fi

	tx=$(printf '%s\n' "$out" | sed -n '/[Ll]aser output power/{
		s/.*\/[[:space:]]*\(-\{0,1\}[0-9][0-9.]*\)[[:space:]]*dBm.*/\1/p
	}' | head -n 1)
	if [ -z "$tx" ]; then
		tx=$(printf '%s\n' "$out" | sed -n '/[Ll]aser output power/{
			s/.*:[[:space:]]*\([0-9][0-9.]*\)[[:space:]]*mW.*/\1/p
		}' | head -n 1)
		[ -n "$tx" ] && tx=$(sm_dbm_from_mw "$tx")
	fi

	[ -n "$temp$rx$tx" ] || return 1
	P_TEMP="$temp"
	P_RX="$rx"
	P_TX="$tx"
	P_DEV="$iface"
	P_SOURCE="ethtool"
	return 0
}

sm_pon_from_hwmon() {
	local h name t p1 p2 found=0
	for h in /sys/class/hwmon/hwmon*; do
		[ -r "$h/name" ] || continue
		name=$(cat "$h/name" 2>/dev/null)
		case "$name" in
			*sfp*|*optic*|*pon*|*xpon*) ;;
			*) continue ;;
		esac
		found=1
		[ -r "$h/temp1_input" ] && t=$(awk -v v="$(cat "$h/temp1_input" 2>/dev/null)" 'BEGIN { printf "%.1f", v / 1000 }')
		# 内核 sfp 驱动以微瓦上报光功率
		[ -r "$h/power1_input" ] && p1=$(awk -v v="$(cat "$h/power1_input" 2>/dev/null)" 'BEGIN { if (v > 0) printf "%.2f", 10 * log(v / 1000000) / log(10) }')
		[ -r "$h/power2_input" ] && p2=$(awk -v v="$(cat "$h/power2_input" 2>/dev/null)" 'BEGIN { if (v > 0) printf "%.2f", 10 * log(v / 1000000) / log(10) }')
		P_TEMP="$t"
		P_TX="$p1"
		P_RX="$p2"
		P_DEV="$name"
		P_SOURCE="hwmon"
		break
	done
	[ "$found" = 1 ]
}

# ---------------------------------------------------------------- 对外接口

sm_pon_json() {
	local cache="$SM_TMP/pon.json" age

	# 光功率变化慢，缓存 10 秒，减少 ponctl 调用
	age=$(sm_age "$cache")
	if [ -s "$cache" ] && [ "$age" -ge 0 ] && [ "$age" -le 10 ]; then
		cat "$cache"
		return
	fi

	P_TEMP=""
	P_RX=""
	P_TX=""
	P_STATE=""
	P_MODE=""
	P_SERIAL=""
	P_ONU=""
	P_DEV=""
	P_SOURCE=""
	P_LIFE=""
	P_VOLT=""
	P_BIAS=""
	P_OPT=""

	if [ "$(sm_pon_cfg enabled 1)" = "1" ]; then
		sm_pon_from_command "$(sm_pon_cfg command '')" ||
			sm_pon_from_ponctl ||
			sm_pon_from_ethtool ||
			sm_pon_from_hwmon || :
	fi

	if [ -z "$P_SOURCE" ]; then
		printf '{"available":false,"source":"none","error":"%s"}' \
			"$(sm_jstr '未检测到 PON 光模块，可在设置中指定采集命令')" >"$cache"
		sm_stamp "$cache"
		cat "$cache"
		return
	fi

	local text opt
	text=$(sm_pon_state_text "$P_STATE")
	[ -n "$text" ] || text=$(sm_pon_lifecycle_text "$P_LIFE")

	case "$P_OPT" in
		true) opt=true ;;
		false) opt=false ;;
		*) opt=null ;;
	esac

	printf '{"available":true,"source":"%s","device":"%s","state":"%s","state_text":"%s","lifecycle":"%s","mode":"%s","temp":%s,"rx_dbm":%s,"tx_dbm":%s,"voltage":%s,"bias":%s,"optical_signal":%s,"onu_id":%s,"serial":"%s"}' \
		"$(sm_jstr "$P_SOURCE")" \
		"$(sm_jstr "$P_DEV")" \
		"$(sm_jstr "$P_STATE")" \
		"$(sm_jstr "$text")" \
		"$(sm_jstr "$P_LIFE")" \
		"$(sm_jstr "$P_MODE")" \
		"$(sm_num_or_null "$P_TEMP")" \
		"$(sm_num_or_null "$P_RX")" \
		"$(sm_num_or_null "$P_TX")" \
		"$(sm_num_or_null "$P_VOLT")" \
		"$(sm_num_or_null "$P_BIAS")" \
		"$opt" \
		"$(sm_num_or_null "$P_ONU")" \
		"$(sm_jstr "$P_SERIAL")" >"$cache"
	sm_stamp "$cache"
	cat "$cache"
}
