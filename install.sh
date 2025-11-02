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

  # 特殊动作：daemon-reload 本身不接服务名
  if [[ "$action" == "daemon-reload" ]]; then
    echo "[TRY] systemctl daemon-reload"
    systemctl daemon-reload 2>/dev/null || true
    return 0
  fi

  # enable 之前先 reload，避免新 unit 看不到
  if [[ "$action" == "enable" ]]; then
    systemctl daemon-reload 2>/dev/null || true
  fi

  local svc alt
  for svc in "$@"; do
    alt="$svc"
    [[ "$svc" == "pmtahttp" ]] && alt="pmtahttpd"

    echo "[TRY] systemctl $action $alt"
    systemctl "$action" "$alt" 2>/dev/null || true

    # restart 失败 → 尝试 start
    if [[ "$action" == "restart" ]]; then
      if ! systemctl is-active --quiet "$alt" 2>/dev/null; then
        echo "[FALLBACK] systemctl start $alt"
        systemctl start "$alt" 2>/dev/null || true
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

pmta_config_test() {
  echo "[STEP] Config test"
  # 优先使用新版语法；若失败再试旧参数
  if pmta test config >/dev/null 2>&1; then
    if ! pmta test config; then
      echo "[ERR] pmta test config failed."
      return 1
    fi
  elif pmta --config-test >/dev/null 2>&1; then
    if ! pmta --config-test; then
      echo "[ERR] pmta --config-test failed."
      return 1
    fi
  else
    echo "[WARN] No known pmta config test command found; skipping."
  fi
}

# ========================
# Begin
# ========================
OS=$(detect_os)
echo "[INFO] Detected OS family: $OS"
[ "$OS" = "unknown" ] && { echo "[ERR] Unsupported OS."; exit 1; }

mkdir -p /etc/pmta
ensure_pmta_user

# 仅当系统无 config 时，用模板生成
if [ ! -f /etc/pmta/config ]; then
  [ -f "$CONFIG_TEMPLATE" ] || { echo "[ERR] Missing template $CONFIG_TEMPLATE"; exit 1; }
  echo "[STEP] Creating /etc/pmta/config from template"
  cp -f "$CONFIG_TEMPLATE" /etc/pmta/config
  safe_replace_placeholders /etc/pmta/config
else
  echo "[INFO] /etc/pmta/config exists; will NOT overwrite."
fi

# 依赖
echo "[STEP] Installing dependencies"
if [ "$OS" = "debian" ]; then
  pkg_install_debian
else
  pkg_install_redhat
fi

# DKIM
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

# 解压
[ -f "$PMTA_ZIP" ] || { echo "[ERR] Missing $PMTA_ZIP"; exit 1; }
echo "[STEP] Unzipping $PMTA_ZIP"
rm -rf "$PMTA_EXTRACT_DIR"
unzip -q "$PMTA_ZIP"

# 停服务
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
  [ -n "${RPM_FILE:-}" ] || { echo "[ERR] No RPM found for RHEL/CentOS."; exit 1; }
  $local_pm -y install "./$RPM_FILE"
fi

# 可执行文件（若包里附带）
[ -f usr/sbin/pmtad ]     && cp -f usr/sbin/pmtad /usr/sbin/pmtad
[ -f usr/sbin/pmtahttpd ] && cp -f usr/sbin/pmtahttpd /usr/sbin/pmtahttpd

cp -f license /etc/pmta/license
chown pmta:pmta /etc/pmta/license 2>/dev/null || true
chmod 600 /etc/pmta/license 2>/dev/null || true


# 权限 & 配置自检
chown -R pmta:pmta /etc/pmta || true
if is_cmd pmta; then
  pmta_config_test || true
fi

# 启动
echo "[STEP] Starting PMTA services"
systemd_try daemon-reload
systemd_try enable pmta pmtahttp pmtahttpd
systemd_try restart pmta pmtahttp pmtahttpd

# 状态 & 端口
echo "[STEP] Service status"
systemctl --no-pager --full status pmta || true
echo "[STEP] Listening ports (25/587)"
is_cmd netstat && netstat -tulnp | grep -E ":25|:587" || true

echo
echo "============================ DKIM TXT (add to DNS) ============================"
cat "${DKIM_DIR}/${DOMAIN}-dkim.txt" || true
echo "==============================================================================="
echo "[DONE] PowerMTA installation finished (non-interactive)."
echo "[INFO] Config: /etc/pmta/config"
echo "[INFO] License: /etc/pmta/license"
