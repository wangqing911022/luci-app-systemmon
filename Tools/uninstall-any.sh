#!/bin/sh
# systemmon 卸载脚本（对应 install.sh 的通用安装）
#   sh uninstall.sh            保留 /etc/config/systemmon
#   sh uninstall.sh --purge    连配置一起删除

/etc/init.d/systemmon stop 2>/dev/null
/etc/init.d/systemmon disable 2>/dev/null

rm -f /etc/rc.d/*systemmon 2>/dev/null
rm -f /etc/init.d/systemmon
rm -f /etc/uci-defaults/95-systemmon
rm -rf /usr/share/systemmon
rm -rf /usr/libexec/systemmon
rm -rf /usr/share/luci-static/resources/view/systemmon
rm -f /usr/share/luci/menu.d/luci-app-systemmon.json

if [ "$1" = "--purge" ]; then
	rm -f /etc/config/systemmon
	echo "已卸载并删除配置"
else
	echo "已卸载，配置保留在 /etc/config/systemmon（加 --purge 一并删除）"
fi
