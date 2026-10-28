#!/bin/sh
# systemmon 通用安装脚本（不需要 opkg/apk，适用于任何 OpenWrt）
#
# 用法：解压后在目录内执行  sh install.sh

set -e

[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/root"
[ -d "$ROOT" ] || { echo "缺少 root/ 目录，请在解压后的目录里运行"; exit 1; }

echo "== 停止已有实例 =="
[ -x /etc/init.d/systemmon ] && /etc/init.d/systemmon stop 2>/dev/null || true

echo "== 复制文件 =="
mkdir -p /usr/libexec /usr/share/systemmon /etc/config /etc/uci-defaults
mkdir -p /usr/share/luci/menu.d /usr/share/luci-static/resources/view/systemmon

rm -rf /usr/libexec/systemmon /usr/share/systemmon/www
cp -rf "$ROOT/usr/libexec/systemmon" /usr/libexec/
cp -rf "$ROOT/usr/share/systemmon/www" /usr/share/systemmon/
cp -f "$ROOT/etc/init.d/systemmon" /etc/init.d/systemmon
cp -f "$ROOT/etc/uci-defaults/95-systemmon" /etc/uci-defaults/95-systemmon

if [ -f /etc/config/systemmon ]; then
	echo "   保留已有配置 /etc/config/systemmon"
else
	cp -f "$ROOT/etc/config/systemmon" /etc/config/systemmon
fi

if [ -f "$ROOT/usr/share/luci/menu.d/luci-app-systemmon.json" ] && [ -d /usr/share/luci/menu.d ]; then
	cp -f "$ROOT/usr/share/luci/menu.d/luci-app-systemmon.json" /usr/share/luci/menu.d/
	cp -f "$ROOT/usr/share/luci-static/resources/view/systemmon/overview.js" \
		/usr/share/luci-static/resources/view/systemmon/
fi

chmod 755 /etc/init.d/systemmon /etc/uci-defaults/95-systemmon
chmod 755 /usr/libexec/systemmon/*.sh /usr/share/systemmon/www/cgi-bin/*
chmod 644 /etc/config/systemmon /usr/share/systemmon/www/index.html \
	/usr/share/systemmon/www/app.css /usr/share/systemmon/www/app.js \
	/usr/share/systemmon/www/favicon.svg

echo "== 启动服务 =="
/etc/init.d/systemmon enable
/etc/init.d/systemmon start
sleep 2

PORT=$(uci -q get systemmon.main.port)
PORT=${PORT:-7752}
IP=$(uci -q get network.lan.ipaddr)
IP=${IP%%/*}
[ -n "$IP" ] || IP=127.0.0.1

if wget -q -O /dev/null -T 5 "http://127.0.0.1:$PORT/cgi-bin/status" 2>/dev/null; then
	echo
	echo "安装完成：http://$IP:$PORT/"
	echo "LuCI 菜单位置：状态 -> 设备监控（无 LuCI 时忽略）"
else
	echo
	echo "服务没有响应，请检查日志：logread | tail -n 20"
	echo "常见原因：$PORT 端口被占用（改 /etc/config/systemmon 里的 port）"
	exit 1
fi
