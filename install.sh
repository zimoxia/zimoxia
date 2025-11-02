#!/usr/bin/env bash
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

CONFIG_SRC="./conf/config"
PMTA_ZIP="./pmta5.0r3.zip"
PMTA_EXTRACT_DIR="pmta5.0r3"

# ========================
# Prechecks
# ========================
if [ "$EUID" -ne 0 ]; then
  echo "[ERR] Please run as root (use sudo)."
  exit 1
fi

if [ ! -f "$CONFIG_SRC" ]; then
  echo "[ERR] Config file not found at $CONFIG_SRC"
  exit 1
fi

if [ ! -f "$PMTA_ZIP" ]; then
  echo "[ERR] PowerMTA zip not found: $PMTA_ZIP"
  exit 1
fi

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
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  # Apache2 / MySQL / PHP 依赖：按需增减
  apt-get install -y \
    opendkim opendkim-tools \
    apache2 php \
    mysql-server php-mysql php-gd php-imap \
    unzip curl ca-certificates
}

pkg_install_redhat() {
  # 某些最小化镜像只有 dnf 或 yum
  local PM=dnf
  is_cmd yum && PM=yum
  $PM -y install \
    opendkim opendkim-tools \
    httpd php \
    mariadb-server php-mysqlnd php-gd php-imap \
    unzip curl ca-certificates
  systemctl enable mariadb || true
}

systemd_try() {
  # $1 action, $2.. services
  local action="$1"; shift
  for svc in "$@"; do
    if systemctl list-unit-files | grep -q "^${svc}\.service"; then
      systemctl "$action" "$svc" || true
    else
      # 兼容某些包的服务命名差异
      case "$svc" in
        pmtahttp)
          if systemctl list-unit-files | grep -q "^pmtahttpd\.service"; then
            systemctl "$action" pmtahttpd || true
          fi
        ;;
      esac
    fi
  done
}

ensure_user_group() {
  # 某些环境未创建 pmta 用户/组时避免 chown 失败
  getent group pmta >/dev/null 2>&1 || groupadd -r pmta
  id -u pmta >/dev/null 2>&1 || useradd -r -g pmta -d /etc/pmta -s /sbin/nologin pmta
}

safe_sed_replace() {
  # 便于反复执行，使用占位符式替换（如果你的 conf/config 已经是示例值，可直接替换）
  # 兼容 GNU sed：-i.bak 生成备份
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

echo "[STEP] Update config placeholders -> /etc/pmta/config"
mkdir -p /etc/pmta
cp -f "$CONFIG_SRC" /etc/pmta/config
safe_sed_replace /etc/pmta/config
echo "[OK] /etc/pmta/config updated."

echo "[STEP] Install dependencies"
case "$OS" in
  debian) pkg_install_debian ;;
  redhat) pkg_install_redhat ;;
  *) echo "[ERR] Unsupported OS. Only Debian/Ubuntu or RHEL/CentOS are supported."; exit 1 ;;
esac

echo "[STEP] Generate DKIM keys via OpenDKIM"
DKIM_DIR="/etc/pmta"
mkdir -p "$DKIM_DIR"
pushd "$DKIM_DIR" >/dev/null
# 清理可能已有的默认文件，避免 opendkim-genkey 覆盖报错
rm -f "${DKIM_SELECTOR}.private" "${DKIM_SELECTOR}.txt"
opendkim-genkey -s "$DKIM_SELECTOR" -d "$DOMAIN"
mv "${DKIM_SELECTOR}.private" "${DOMAIN}-dkim.key"
mv "${DKIM_SELECTOR}.txt"     "${DOMAIN}-dkim.txt"
chmod 600 "${DOMAIN}-dkim.key"
popd >/dev/null
echo "[OK] DKIM key: ${DKIM_DIR}/${DOMAIN}-dkim.key"
echo "[OK] DKIM TXT: ${DKIM_DIR}/${DOMAIN}-dkim.txt"

echo "[STEP] Unzip PowerMTA package"
rm -rf "$PMTA_EXTRACT_DIR"
unzip -q "$PMTA_ZIP"
cd "$PMTA_EXTRACT_DIR"

echo "[STEP] Stop PMTA services (if any)"
systemd_try stop pmta pmtahttp pmtahttpd

echo "[STEP] Install PowerMTA"
if [ "$OS" = "debian" ]; then
  # 优先 .deb
  DEB_FILE=$(ls -1 *.deb 2>/dev/null | head -n1 || true)
  if [ -n "${DEB_FILE:-}" ]; then
    dpkg -i "$DEB_FILE" || apt-get install -f -y
  else
    # 兜底：如果压缩包里只有 rpm（极少数情况）
    RPM_FILE=$(ls -1 *.rpm 2>/dev/null | head -n1 || true)
    if [ -n "${RPM_FILE:-}" ]; then
      echo "[WARN] No .deb found, but RPM exists. Converting via alien..."
      apt-get install -y alien
      alien -i "$RPM_FILE"
    else
      echo "[ERR] No PowerMTA package (*.deb or *.rpm) found in $PMTA_EXTRACT_DIR"
      exit 1
    fi
  fi
else
  # RHEL/CentOS
  RPM_FILE=$(ls -1 *.rpm 2>/dev/null | head -n1 || true)
  if [ -n "${RPM_FILE:-}" ]; then
    local_pm=yum
    is_cmd dnf && local_pm=dnf
    $local_pm -y install "$RPM_FILE"
  else
    echo "[ERR] No RPM found for RHEL/CentOS"
    exit 1
  fi
fi

echo "[STEP] Copy binaries/license/config if present in package tree (idempotent)"
# 某些包会把这些文件也包含在解包目录的 usr/ 或 license/ 下
ensure_user_group
[ -f usr/sbin/pmtad ]      && cp -f usr/sbin/pmtad /usr/sbin/pmtad
[ -f usr/sbin/pmtahttpd ]  && cp -f usr/sbin/pmtahttpd /usr/sbin/pmtahttpd
[ -d license ]             && mkdir -p /etc/pmta/license && cp -rf license/* /etc/pmta/license/ || true

# 确保权限
chown -R pmta:pmta /etc/pmta || true

echo "[STEP] Enable & restart PMTA services"
# 部分安装包服务名是 pmtahttp 或 pmtahttpd，下面都尝试
systemd_try daemon-reload
systemd_try enable pmta pmtahttp pmtahttpd
systemd_try restart pmta pmtahttp pmtahttpd

echo
echo "============================ DKIM TXT (add to DNS) ============================"
cat "${DKIM_DIR}/${DOMAIN}-dkim.txt" || true
echo "==============================================================================="
echo "[DONE] PowerMTA installation & basic config completed."
echo "[INFO] Config: /etc/pmta/config"
echo "[INFO] DKIM key: ${DKIM_DIR}/${DOMAIN}-dkim.key"
echo "[INFO] DKIM txt: ${DKIM_DIR}/${DOMAIN}-dkim.txt"
