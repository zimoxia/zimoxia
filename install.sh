#!/bin/bash
set -euo pipefail

# ========================
# Usage & Inputs
# ========================
if [ $# -ne 4 ]; then
  echo "Usage: sudo ./install.sh <domain> <ip> <email_prefix> <email_password>"
  exit 1
fi

DOMAIN="$1"
IP="$2"
EMAIL_PREFIX="$3"
EMAIL_PASSWORD="$4"
DKIM_SELECTOR="default"

CONFIG_TEMPLATE="./conf/config"
PMTA_ZIP="./pmta5.0r3.zip"
PMTA_EXTRACT_DIR="pmta5.0r3"

export DEBIAN_FRONTEND=noninteractive

# ========================
# Helpers
# ========================
is_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
  if [ -f /etc/debian_version ] && is_cmd apt-get; then
    echo "debian"
  elif [ -f /etc/redhat-release ] && (is_cmd yum || is_cmd dnf); then
    echo "redhat"
  else
    echo "unknown"
  fi
}

pkg_install_debian() {
  apt-get update
  apt-get install -y --no-install-recommends \
    opendkim opendkim-tools \
    apache2 php \
    mysql-server php-mysql php-gd php-imap \
    unzip curl ca-certificates net-tools
}

pkg_install_redhat() {
  local PM=dnf
  is_cmd yum && PM=yum
  $PM -y install \
    opendkim \
    httpd php \
    mariadb-server php-mysqlnd php-gd php-imap \
    unzip curl ca-certificates net-tools
  systemctl enable mariadb || true
}

systemd_try() {
  local action="$1"; shift
  for svc in "$@"; do
    if systemctl list-unit-files | grep -q "^${svc}\.service"; then
      systemctl "$action" "$svc" || true
    else
      # 某些发行包服务名可能是 pmtahttpd
      if [ "$svc" = "pmtahttp" ] && systemctl list-unit-files | grep -q "^pmtahttpd\.service"; then
        systemctl "$action" pmtahttpd || true
      fi
    fi
  done
}

ensure_pmta_user() {
  getent group pmta >/dev/null 2>&1 || groupadd -r pmta
  id -u pmta >/dev/null 2>&1 || useradd -r -g pmta -d /etc/pmta -s /usr/sbin/nologin pmta
}

safe_replace_placeholders() {
  local file="$1"
  sed -i.bak \
    -e "s/domain\.com/$DOMAIN/g" \
    -e "s/192\.168\.1\.13/$IP/g" \
    -e "s/\badmin\b/$EMAIL_PREFIX/g" \
    -e "s/\bvip250\b/$EMAIL_PASSWORD/g" \
    "$file"
}

# ========================
# Begin
# ========================
OS=$(detect_os)
echo "[INFO] Detected OS family: $OS"
if [ "$OS" = "unknown" ]; then
  echo "[ERR] Unsupported OS."
  exit 1
fi

# 基础目录
mkdir -p /etc/pmta
ensure_pmta_user

# 如果系统尚无 config，则用模板生成；如果已有，绝不覆盖
if [ ! -f /etc/pmta/config ]; then
  if [ ! -f "$CONFIG_TEMPLATE" ]; then
    echo "[ERR] /etc/pmta/config not found and no template at $CONFIG_TEMPLATE"
    exit 1
  fi
  echo "[STEP] Creating initial /etc/pmta/config from template"
  cp -f "$CONFIG_TEMPLATE" /etc/pmta/config
  safe_replace_placeholders /etc/pmta/config
else
  echo "[INFO] /etc/pmta/config exists; will NOT overwrite."
fi

# 安装依赖
echo "[STEP] Installing dependencies"
if [ "$OS" = "debian" ]; then
  pkg_install_debian
else
  pkg_install_redhat
fi

# 生成 DKIM（可幂等）
echo "[STEP] Generating DKIM keys"
DKIM_DIR="/etc/pmta"
pushd "$DKIM_DIR" >/dev/null
rm -f "${DKIM_SELECTOR}.private" "${DKIM_SELECTOR}.txt" || true
opendkim-genkey -s "$DKIM_SELECTOR" -d "$DOMAIN"
mv "${DKIM_SELECTOR}.private" "${DOMAIN}-dkim.key"
mv "${DKIM_SELECTOR}.txt"     "${DOMAIN}-dkim.txt"
chmod 600 "${DOMAIN}-dkim.key"
popd >/dev/null
chown -R pmta:pmta /etc/pmta || true
echo "[OK] DKIM key: ${DKIM_DIR}/${DOMAIN}-dkim.key"
echo "[OK] DKIM TXT: ${DKIM_DIR}/${DOMAIN}-dkim.txt"

# 解压安装包
if [ ! -f "$PMTA_ZIP" ]; then
  echo "[ERR] Missing $PMTA_ZIP"
  exit 1
fi
echo "[STEP] Unzipping $PMTA_ZIP"
rm -rf "$PMTA_EXTRACT_DIR"
unzip -q "$PMTA_ZIP"

# 停服务（若已存在）
systemd_try stop pmta pmtahttp pmtahttpd

# 安装 PowerMTA
echo "[STEP] Installing PowerMTA"
pushd "$PMTA_EXTRACT_DIR" >/dev/null
if [ "$OS" = "debian" ]; then
  DEB_FILE=$(ls -1 *.deb 2>/dev/null | head -n1 || true)
  if [ -n "${DEB_FILE:-}" ]; then
    echo "[INFO] Installing $DEB_FILE (keep existing /etc/pmta/config)"
    apt-get install -y -o Dpkg::Options::="--force-confold" "./$DEB_FILE"
  else
    RPM_FILE=$(ls -1 *.rpm 2>/dev/null | head -n1 || true)
    if [ -n "${RPM_FILE:-}" ]; then
      echo "[WARN] No .deb found; converting rpm via alien (keep config)"
      apt-get install -y alien
      alien -i "$RPM_FILE"
    else
      echo "[ERR] No PowerMTA package (*.deb or *.rpm) found."
      exit 1
    fi
  fi
else
  local_pm=dnf
  is_cmd yum && local_pm=yum
  RPM_FILE=$(ls -1 *.rpm 2>/dev/null | head -n1 || true)
  if [ -n "${RPM_FILE:-}" ]; then
    $local_pm -y install "./$RPM_FILE"
  else
    echo "[ERR] No RPM found for RHEL/CentOS."
    exit 1
  fi
fi

# 拷贝可执行文件（若包里提供了额外版本）
[ -f usr/sbin/pmtad ]     && cp -f usr/sbin/pmtad /usr/sbin/pmtad
[ -f usr/sbin/pmtahttpd ] && cp -f usr/sbin/pmtahttpd /usr/sbin/pmtahttpd

# 复制 license（不论文件还是目录，统一拷到 /etc/pmta/license）
echo "[STEP] Copy license"
mkdir -p /etc/pmta/license
if [ -e "license" ]; then
  # 先整体拷贝（兼容 license 为文件/目录）
  cp -rf "license" /etc/pmta/ 2>/dev/null || true
  # 若是目录，拷贝其中文件到目标目录
  cp -rf "license"/* /etc/pmta/license/ 2>/dev/null || true
  echo "[OK] License copied to /etc/pmta/license"
else
  echo "[WARN] No 'license' found in $PMTA_EXTRACT_DIR. PMTA may not start."
fi

popd >/dev/null

# 权限修正
chown -R pmta:pmta /etc/pmta || true

# 配置自检（若 pmta 在 PATH）
if is_cmd pmta; then
  echo "[STEP] pmta --config-test"
  if ! pmta --config-test; then
    echo "[ERR] Config test failed. Please check /etc/pmta/config"
  fi
fi

# 启动服务
echo "[STEP] Starting PMTA services"
systemd_try daemon-reload
systemd_try enable pmta pmtahttp pmtahttpd
systemd_try restart pmta pmtahttp pmtahttpd

# 状态与端口检测
echo "[STEP] Service status"
systemctl --no-pager --full status pmta || true

echo "[STEP] Listening ports (25/587)"
if is_cmd netstat; then
  netstat -tulnp | grep -E ":25|:587" || true
fi

echo
echo "============================ DKIM TXT (add to DNS) ============================"
cat "${DKIM_DIR}/${DOMAIN}-dkim.txt" || true
echo "==============================================================================="
echo "[DONE] PowerMTA installation finished (non-interactive)."
echo "[INFO] Config: /etc/pmta/config"
echo "[INFO] License: /etc/pmta/license"
