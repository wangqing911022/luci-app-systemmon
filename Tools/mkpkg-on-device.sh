#!/bin/sh
# 在路由器本机用 apk-tools 打包（需要设备上有 `apk mkpkg`）
#
# 用法（把 luci-app-systemmon 整个目录传到设备后，在仓库任意位置）：
#   sh Tools/mkpkg-on-device.sh [输出目录]
#
# 产物默认写到 /tmp/systemmon-*.apk，可直接：
#   apk add --allow-untrusted /tmp/systemmon-1.3.0-r1.apk

set -e

SRC=$(cd "$(dirname "$0")/.." && pwd)
PKGDIR="$SRC/luci-app-systemmon"
OUT="${1:-/tmp}"
VER="1.3.0-r1"

[ -d "$PKGDIR/files" ] || { echo "找不到 $PKGDIR/files"; exit 1; }
command -v apk >/dev/null 2>&1 || { echo "当前系统没有 apk"; exit 1; }
apk mkpkg --help >/dev/null 2>&1 || { echo "该 apk 不支持 mkpkg 子命令"; exit 1; }

CTL=$(mktemp -d /tmp/systemmon-ctl.XXXXXX) || exit 1
trap 'rm -rf "$CTL"' EXIT INT TERM

cat >"$CTL/postinst" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
	/etc/init.d/systemmon enable >/dev/null 2>&1
	/etc/init.d/systemmon restart >/dev/null 2>&1
}
exit 0
EOF

cat >"$CTL/prerm" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
	/etc/init.d/systemmon stop >/dev/null 2>&1
	/etc/init.d/systemmon disable >/dev/null 2>&1
}
exit 0
EOF

chmod 755 "$CTL/postinst" "$CTL/prerm"

echo "打包 systemmon ..."
apk mkpkg \
	--info "name:systemmon" \
	--info "version:$VER" \
	--info "arch:noarch" \
	--info "license:MIT" \
	--info "origin:systemmon" \
	--info "description:本机与局域网设备状态监控（CPU/内存/温度/PON 光功率），Web 端口 7752" \
	--info "depends:libc uhttpd" \
	--info "tags:openwrt:section=admin" \
	--script "post-install:$CTL/postinst" \
	--script "pre-deinstall:$CTL/prerm" \
	--files "$PKGDIR/files" \
	--output "$OUT/systemmon-$VER.apk"

echo "打包 luci-app-systemmon ..."
apk mkpkg \
	--info "name:luci-app-systemmon" \
	--info "version:$VER" \
	--info "arch:noarch" \
	--info "license:MIT" \
	--info "origin:systemmon" \
	--info "description:LuCI 菜单入口 状态 -> 设备监控" \
	--info "depends:libc systemmon luci-base" \
	--info "tags:openwrt:section=luci" \
	--files "$PKGDIR/luci" \
	--output "$OUT/luci-app-systemmon-$VER.apk"

echo "完成：$OUT"
