# SPDX-License-Identifier: GPL-3.0-or-later

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for Stargate
LUCI_DEPENDS:=+luci-base +rpcd +rpcd-mod-file +rpcd-mod-luci +sing-box
LUCI_PKGARCH:=all

define Package/luci-app-stargate/conffiles
/etc/config/stargate
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
