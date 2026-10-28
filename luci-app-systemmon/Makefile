#
# systemmon - 本机 / 局域网设备状态监控（Web 服务，端口 7752）
#
# 纯脚本 + 静态页面，无编译产物，固件架构无关（PKGARCH:=all）。
# 同一份源码在不同 SDK 下会自动产出 .ipk（opkg）或 .apk（apk-tools 3）。
#

include $(TOPDIR)/rules.mk

PKG_NAME:=systemmon
PKG_VERSION:=1.3.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=WQ

include $(INCLUDE_DIR)/package.mk

# 纯文件包：没有源码、没有构建系统，必须显式覆盖 Prepare/Compile，
# 否则框架会在空的 PKG_BUILD_DIR 里执行 make 并报
# "No targets specified and no makefile found"。
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
	true
endef

define Package/systemmon
  SECTION:=admin
  CATEGORY:=Administration
  TITLE:=System and LAN device status dashboard (HTTP port 7752)
  URL:=https://github.com/wangqing911022/luci-app-systemmon
  DEPENDS:=+uhttpd
  PKGARCH:=all
endef

define Package/systemmon/description
  Lightweight monitor for the router itself and other LAN devices.
  Collects CPU usage, memory usage, SoC/SFP temperature, PON temperature
  and optical Rx/Tx power (via airoha-ponctl when available), and exposes
  everything through a self-contained Chinese web dashboard on port 7752.
  No external assets, no daemon: metrics are collected per request.
endef

define Package/systemmon/conffiles
/etc/config/systemmon
endef

define Package/systemmon/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/systemmon $(1)/etc/config/systemmon
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/systemmon $(1)/etc/init.d/systemmon
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/95-systemmon $(1)/etc/uci-defaults/95-systemmon
	$(INSTALL_DIR) $(1)/usr/libexec/systemmon
	$(INSTALL_BIN) ./files/usr/libexec/systemmon/common.sh $(1)/usr/libexec/systemmon/
	$(INSTALL_BIN) ./files/usr/libexec/systemmon/system.sh $(1)/usr/libexec/systemmon/
	$(INSTALL_BIN) ./files/usr/libexec/systemmon/pon.sh $(1)/usr/libexec/systemmon/
	$(INSTALL_BIN) ./files/usr/libexec/systemmon/devices.sh $(1)/usr/libexec/systemmon/
	$(INSTALL_BIN) ./files/usr/libexec/systemmon/agent.sh $(1)/usr/libexec/systemmon/
	$(INSTALL_DIR) $(1)/usr/share/systemmon/www/cgi-bin
	$(INSTALL_DATA) ./files/usr/share/systemmon/www/index.html $(1)/usr/share/systemmon/www/
	$(INSTALL_DATA) ./files/usr/share/systemmon/www/app.css $(1)/usr/share/systemmon/www/
	$(INSTALL_DATA) ./files/usr/share/systemmon/www/app.js $(1)/usr/share/systemmon/www/
	$(INSTALL_DATA) ./files/usr/share/systemmon/www/favicon.svg $(1)/usr/share/systemmon/www/
	$(INSTALL_BIN) ./files/usr/share/systemmon/www/cgi-bin/status $(1)/usr/share/systemmon/www/cgi-bin/
	$(INSTALL_BIN) ./files/usr/share/systemmon/www/cgi-bin/devices $(1)/usr/share/systemmon/www/cgi-bin/
	$(INSTALL_BIN) ./files/usr/share/systemmon/www/cgi-bin/discover $(1)/usr/share/systemmon/www/cgi-bin/
	$(INSTALL_BIN) ./files/usr/share/systemmon/www/cgi-bin/agent $(1)/usr/share/systemmon/www/cgi-bin/
	$(INSTALL_BIN) ./files/usr/share/systemmon/www/cgi-bin/config $(1)/usr/share/systemmon/www/cgi-bin/
	$(INSTALL_BIN) ./files/usr/share/systemmon/www/cgi-bin/diag $(1)/usr/share/systemmon/www/cgi-bin/
endef

define Package/systemmon/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/systemmon enable >/dev/null 2>&1
	/etc/init.d/systemmon restart >/dev/null 2>&1
}
exit 0
endef

define Package/systemmon/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/systemmon stop >/dev/null 2>&1
	/etc/init.d/systemmon disable >/dev/null 2>&1
}
exit 0
endef

define Package/luci-app-systemmon
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI menu entry for systemmon dashboard
  URL:=https://github.com/wangqing911022/luci-app-systemmon
  DEPENDS:=+systemmon +luci-base
  PKGARCH:=all
endef

define Package/luci-app-systemmon/description
  Adds a "设备监控" entry under LuCI -> Status which embeds the systemmon
  dashboard served on port 7752.
endef

define Package/luci-app-systemmon/install
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./luci/usr/share/luci/menu.d/luci-app-systemmon.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DIR) $(1)/usr/share/luci-static/resources/view/systemmon
	$(INSTALL_DATA) ./luci/usr/share/luci-static/resources/view/systemmon/overview.js $(1)/usr/share/luci-static/resources/view/systemmon/
endef

$(eval $(call BuildPackage,systemmon))
$(eval $(call BuildPackage,luci-app-systemmon))
