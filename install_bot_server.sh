#!/usr/bin/env bash
# Bot Server Installer + optional /bot migration
# Target: Ubuntu 22.04/24.04 and compatible Debian systems.
# This script configures Apache TLS on TCP/80, keeps TCP/443 free for Xray,
# and can copy /bot from a remote root server over SSH without deleting source data.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_NAME="Bot Server Installer"
MANAGED_NAME="bot-server-installer"
WEBROOT="/bot"
LE_WEBROOT="/var/lib/letsencrypt"
BACKUP_ROOT="/var/backups/${MANAGED_NAME}"
ACTIVE_CONF="/etc/apache2/sites-available/${MANAGED_NAME}.conf"
ENABLED_CONF="/etc/apache2/sites-enabled/${MANAGED_NAME}.conf"
HTTP_TEMPLATE="/etc/${MANAGED_NAME}/${MANAGED_NAME}.http.conf"
HTTPS_TEMPLATE="/etc/${MANAGED_NAME}/${MANAGED_NAME}.https.conf"
HOOK_SCRIPT="/usr/local/sbin/${MANAGED_NAME}-certbot-hook"
DOMAIN=""
REMOTE_IP=""
REMOTE_PASSWORD=""
SSH_PASS_FILE=""
STAGE_DIR=""
MIGRATION_COMMITTED=0
POLICY_FILE_CREATED=0
SSL_ACTIVE=0
APT_UPDATED=0

say()  { printf '\n\033[1;36m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

cleanup() {
    local rc=$?
    unset SSHPASS REMOTE_PASSWORD 2>/dev/null || true
    [[ -n "${SSH_PASS_FILE:-}" ]] && rm -f "$SSH_PASS_FILE" 2>/dev/null || true
    if [[ "$POLICY_FILE_CREATED" -eq 1 ]]; then
        rm -f /usr/sbin/policy-rc.d 2>/dev/null || true
    fi
    if [[ -n "${STAGE_DIR:-}" && -d "$STAGE_DIR" && "$MIGRATION_COMMITTED" -eq 0 ]]; then
        rm -rf --one-file-system "$STAGE_DIR" 2>/dev/null || true
    fi
    exit "$rc"
}
trap cleanup EXIT

need_root() {
    [[ "$(id -u)" -eq 0 ]] || die "این نصب‌کننده را با کاربر root اجرا کن."
}

validate_domain() {
    local value="$1"
    [[ "$value" == "${value,,}" ]] || value="${value,,}"
    [[ "$value" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || return 1
    [[ ${#value} -le 253 ]] || return 1
    printf '%s' "$value"
}

validate_ipv4() {
    local value="$1" part
    local -a octets
    [[ "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$value"
    [[ "${#octets[@]}" -eq 4 ]] || return 1
    for part in "${octets[@]}"; do
        # Force decimal interpretation and reject values outside IPv4 range.
        (( 10#$part <= 255 )) || return 1
    done
    return 0
}

backup_file() {
    local file="$1"
    [[ -e "$file" || -L "$file" ]] || return 0
    mkdir -p "$BACKUP_ROOT"
    local stamp
    stamp="$(date +%Y%m%d_%H%M%S)"
    cp -a -- "$file" "$BACKUP_ROOT/$(basename "$file").$stamp"
}

port_owner() {
    local port="$1"
    ss -H -ltnp "sport = :$port" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | sort -u | paste -sd, -
}

check_os() {
    [[ -r /etc/os-release ]] || die "تشخیص سیستم‌عامل ممکن نیست."
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) ;;
        *) die "این نسخه برای Ubuntu/Debian طراحی شده؛ سیستم فعلی: ${PRETTY_NAME:-unknown}" ;;
    esac
}

install_packages() {
    say "نصب پیش‌نیازهای Apache، PHP و Certbot..."
    local policy_created=0
    # Prevent package post-install scripts from starting Apache before we reserve 443 for Xray.
    if [[ ! -e /usr/sbin/policy-rc.d ]]; then
        cat > /usr/sbin/policy-rc.d <<'POLICY'
#!/bin/sh
exit 101
POLICY
        chmod 755 /usr/sbin/policy-rc.d
        policy_created=1
        POLICY_FILE_CREATED=1
    fi

    export DEBIAN_FRONTEND=noninteractive
    if [[ "$APT_UPDATED" -eq 0 ]] && ! apt-get update; then
        unset DEBIAN_FRONTEND
        if [[ "$policy_created" -eq 1 ]]; then rm -f /usr/sbin/policy-rc.d; POLICY_FILE_CREATED=0; fi
        die "به‌روزرسانی فهرست بسته‌ها ناموفق بود."
    fi
    if ! apt-get install -y --no-install-recommends \
        apache2 certbot \
        php-cli libapache2-mod-php php-curl php-mbstring php-xml \
        php-mysql php-sqlite3 php-zip php-gd php-bcmath php-intl \
        php-bz2 php-opcache curl ca-certificates openssl \
        python3-certbot-apache openssh-client tar gzip python3; then
        unset DEBIAN_FRONTEND
        if [[ "$policy_created" -eq 1 ]]; then rm -f /usr/sbin/policy-rc.d; POLICY_FILE_CREATED=0; fi
        die "نصب پیش‌نیازها ناموفق بود."
    fi
    unset DEBIAN_FRONTEND
    APT_UPDATED=1
    if [[ "$policy_created" -eq 1 ]]; then rm -f /usr/sbin/policy-rc.d; POLICY_FILE_CREATED=0; fi
    ok "پیش‌نیازهای وب نصب شدند."
}

prepare_apache_ports() {
    local owner443="${1:-}"
    if [[ "$owner443" == *apache2* ]]; then
        die "Apache پیش از اجرای نصب‌کننده پورت 443 را گرفته بود. برای جلوگیری از قطع سایت موجود، ادامه ندادم."
    fi

    # If another service (for example Xray) owns 443, Apache must not try to bind it.
    # Keep a dated copy before changing Apache's Listen directives.
    local ports_conf="/etc/apache2/ports.conf"
    [[ -f "$ports_conf" ]] || die "فایل $ports_conf پیدا نشد."
    if grep -Eq '^[[:space:]]*Listen[[:space:]]+443([[:space:]]|$)' "$ports_conf"; then
        backup_file "$ports_conf"
        sed -i -E '/^[[:space:]]*Listen[[:space:]]+443([[:space:]]|$)/s/^([[:space:]]*)Listen/# \1Listen 443 disabled by bot-server-installer (keep 443 free for Xray)/' "$ports_conf"
        ok "Apache دیگر پورت 443 را اشغال نمی‌کند؛ پورت برای Xray آزاد می‌ماند."
    fi

    if ! grep -Eq '^[[:space:]]*Listen[[:space:]]+80([[:space:]]|$)' "$ports_conf"; then
        backup_file "$ports_conf"
        printf '\nListen 80\n' >> "$ports_conf"
    fi

    # Restart after changing Listen 443; if apt started Apache on 443, this releases it.
    if systemctl is-active --quiet apache2; then
        systemctl restart apache2
    fi
}

check_port80_and_vhosts() {
    local owner80 f base
    owner80="$(port_owner 80 || true)"
    if [[ -n "$owner80" && "$owner80" != *apache2* ]]; then
        die "پورت 80 در اختیار سرویس دیگری است: $owner80 . برای جلوگیری از قطعی، ادامه ندادم."
    fi

    # HTTPS on port 80 and clear-text HTTP cannot safely share the same listener.
    # Only the stock Ubuntu default site may be disabled automatically.
    shopt -s nullglob
    for f in /etc/apache2/sites-enabled/*.conf; do
        base="$(basename "$f")"
        [[ "$base" == "${MANAGED_NAME}.conf" ]] && continue
        if grep -Eiq '<VirtualHost[^>]*(:80)([[:space:]>]|$)' "$f"; then
            if [[ "$base" == "000-default.conf" ]]; then
                backup_file "$f"
                a2dissite 000-default >/dev/null 2>&1 || true
                ok "سایت پیش‌فرض Apache غیرفعال شد (فایل اصلی حفظ شده است)."
            else
                die "یک VirtualHost دیگر روی پورت 80 فعال است: $base . چون HTTPS روی 80 انتخاب شده، برای جلوگیری از خراب شدن سایت قبلی آن را خودکار غیرفعال نکردم."
            fi
        fi
    done
    shopt -u nullglob

    # Do not silently replace another domain's vhost.
    if [[ -e "$ACTIVE_CONF" ]]; then
        backup_file "$ACTIVE_CONF"
    fi
    if [[ -e "$ENABLED_CONF" && ! -L "$ENABLED_CONF" ]]; then
        die "مسیر فعال $ENABLED_CONF فایل معمولی است؛ برای جلوگیری از بازنویسی، ادامه متوقف شد."
    fi
    if [[ -L "$ENABLED_CONF" && "$(readlink -f "$ENABLED_CONF")" != "$ACTIVE_CONF" ]]; then
        die "مسیر فعال $ENABLED_CONF به فایل دیگری اشاره می‌کند؛ ادامه متوقف شد."
    fi
}

write_vhost_templates() {
    local domain="$1"
    mkdir -p "/etc/${MANAGED_NAME}" "$LE_WEBROOT/.well-known/acme-challenge"
    if [[ ! -d "$WEBROOT" ]]; then
        mkdir -p "$WEBROOT"
        chown www-data:www-data "$WEBROOT"
        chmod 755 "$WEBROOT"
    fi
    chmod 755 "$LE_WEBROOT" "$LE_WEBROOT/.well-known" "$LE_WEBROOT/.well-known/acme-challenge"

    cat > "$HTTP_TEMPLATE" <<EOF
<VirtualHost *:80>
    ServerName ${domain}
    DocumentRoot ${WEBROOT}

    Alias /.well-known/acme-challenge/ ${LE_WEBROOT}/.well-known/acme-challenge/
    <Directory "${LE_WEBROOT}/.well-known/acme-challenge/">
        Options None
        AllowOverride None
        Require all granted
    </Directory>

    <Directory "${WEBROOT}">
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
        DirectoryIndex ma.php index.php index.html
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${MANAGED_NAME}-error.log
    CustomLog \${APACHE_LOG_DIR}/${MANAGED_NAME}-access.log combined
</VirtualHost>
EOF

    cat > "$HTTPS_TEMPLATE" <<EOF
<VirtualHost *:80>
    ServerName ${domain}
    DocumentRoot ${WEBROOT}

    <Directory "${WEBROOT}">
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
        DirectoryIndex ma.php index.php index.html
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${MANAGED_NAME}-error.log
    CustomLog \${APACHE_LOG_DIR}/${MANAGED_NAME}-access.log combined

    SSLEngine on
    SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1
    SSLCompression off
    SSLCertificateFile /etc/letsencrypt/live/${domain}/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/${domain}/privkey.pem
    <IfModule mod_ssl.c>
        IncludeOptional /etc/letsencrypt/options-ssl-apache.conf
    </IfModule>
</VirtualHost>
EOF

    chmod 644 "$HTTP_TEMPLATE" "$HTTPS_TEMPLATE"
    install -m 0644 "$HTTP_TEMPLATE" "$ACTIVE_CONF"
    if [[ ! -e "$ENABLED_CONF" ]]; then
        ln -s "$ACTIVE_CONF" "$ENABLED_CONF"
    fi
}

write_certbot_hook() {
    local domain="$1"
    cat > "$HOOK_SCRIPT" <<'HOOK'
#!/usr/bin/env bash
set -Eeuo pipefail
MODE="${1:-}"
DOMAIN="__BOT_INSTALLER_DOMAIN__"
ACTIVE="/etc/apache2/sites-available/bot-server-installer.conf"
HTTP="/etc/bot-server-installer/bot-server-installer.http.conf"
HTTPS="/etc/bot-server-installer/bot-server-installer.https.conf"
BACKUP="/var/lib/bot-server-installer/${DOMAIN}.pre-renew.conf"
CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
mkdir -p /var/lib/bot-server-installer

restore_mode() {
    local src="$1"
    local tmp="${ACTIVE}.hooktmp"
    local rollback="${ACTIVE}.rollback"
    [[ -f "$ACTIVE" ]] && cp -a "$ACTIVE" "$rollback"
    install -m 0644 "$src" "$tmp"
    mv -f "$tmp" "$ACTIVE"
    if ! apache2ctl configtest >/dev/null 2>&1 || ! systemctl reload apache2; then
        if [[ -f "$rollback" ]]; then
            install -m 0644 "$rollback" "$ACTIVE"
            apache2ctl configtest >/dev/null 2>&1 && systemctl reload apache2 || true
        fi
        rm -f "$tmp" "$rollback"
        return 1
    fi
    rm -f "$rollback"
}

case "$MODE" in
  pre)
    [[ -f "$ACTIVE" ]] && cp -a "$ACTIVE" "$BACKUP"
    restore_mode "$HTTP"
    ;;
  post)
    if [[ -s "$CERT" && -s "$KEY" ]] && openssl x509 -in "$CERT" -noout >/dev/null 2>&1; then
        restore_mode "$HTTPS"
    else
        restore_mode "$HTTP"
    fi
    rm -f "$BACKUP"
    ;;
  *) echo "Usage: $0 pre|post" >&2; exit 2 ;;
esac
HOOK
    sed -i "s/__BOT_INSTALLER_DOMAIN__/${domain}/g" "$HOOK_SCRIPT"
    chmod 750 "$HOOK_SCRIPT"
    chown root:root "$HOOK_SCRIPT"
}

install_global_renewal_hooks() {
    local pre_dir="/etc/letsencrypt/renewal-hooks/pre"
    local post_dir="/etc/letsencrypt/renewal-hooks/post"
    local pre_file="${pre_dir}/50-bot-server-installer"
    local post_file="${post_dir}/50-bot-server-installer"
    mkdir -p "$pre_dir" "$post_dir"
    backup_file "$pre_file"
    backup_file "$post_file"
    cat > "$pre_file" <<'PRE'
#!/bin/sh
exec /usr/local/sbin/bot-server-installer-certbot-hook pre
PRE
    cat > "$post_file" <<'POST'
#!/bin/sh
exec /usr/local/sbin/bot-server-installer-certbot-hook post
POST
    chmod 750 "$pre_file" "$post_file"
    chown root:root "$pre_file" "$post_file"
}

activate_http() {
    install -m 0644 "$HTTP_TEMPLATE" "${ACTIVE_CONF}.tmp"
    mv -f "${ACTIVE_CONF}.tmp" "$ACTIVE_CONF"
    apache2ctl configtest
    systemctl reload apache2 2>/dev/null || systemctl restart apache2
}

activate_https() {
    install -m 0644 "$HTTPS_TEMPLATE" "${ACTIVE_CONF}.tmp"
    mv -f "${ACTIVE_CONF}.tmp" "$ACTIVE_CONF"
    if apache2ctl configtest; then
        systemctl reload apache2 2>/dev/null || systemctl restart apache2
        return 0
    fi
    warn "پیکربندی HTTPS معتبر نشد؛ پیکربندی HTTP بازیابی می‌شود."
    activate_http
    return 1
}

configure_domain_ssl() {
    local domain="$1"
    local cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
    local key="/etc/letsencrypt/live/${domain}/privkey.pem"
    local cert_ok=0
    local hooks_ready=0

    say "تنظیم دامنه ${domain} روی HTTPS و پورت 80..."
    a2enmod ssl rewrite headers >/dev/null

    # Apache must not bind 443; port 80 remains the only listener for this vhost.
    if ! grep -Eq '^[[:space:]]*Listen[[:space:]]+80([[:space:]]|$)' /etc/apache2/ports.conf; then
        printf '\nListen 80\n' >> /etc/apache2/ports.conf
    fi

    write_vhost_templates "$domain"
    write_certbot_hook "$domain"

    # Make sure the HTTP challenge vhost is active before asking Let's Encrypt.
    activate_http

    if [[ -s "$cert" && -s "$key" ]] && openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null 2>&1; then
        say "گواهی معتبر موجود است؛ درخواست گواهی جدید ارسال نمی‌شود."
        cert_ok=1
    else
        say "درخواست گواهی Let's Encrypt..."
        if timeout 240 certbot certonly \
            --webroot -w "$LE_WEBROOT" \
            --cert-name "$domain" -d "$domain" \
            --agree-tos --register-unsafely-without-email \
            --non-interactive --no-eff-email; then
            if [[ -s "$cert" && -s "$key" ]] && openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null 2>&1; then
                cert_ok=1
            fi
        else
            warn "صدور SSL موفق نشد. احتمالاً DNS دامنه هنوز به IP همین سرور اشاره نمی‌کند یا TCP/80 از اینترنت قابل دسترسی نیست."
        fi
    fi

    if [[ "$cert_ok" -eq 1 ]]; then
        # Prefer per-certificate hooks (Certbot 2.3+). On older clients,
        # fall back to Certbot's renewal-hooks directories.
        local reconfigure_ok=0
        if certbot reconfigure --help 2>&1 | grep -q -- '--pre-hook'; then
            say "ثبت hookهای اختصاصی تمدید برای همین دامنه..."
            if timeout 240 certbot reconfigure --cert-name "$domain" \
                --pre-hook "${HOOK_SCRIPT} pre" \
                --post-hook "${HOOK_SCRIPT} post" \
                --non-interactive; then
                reconfigure_ok=1
                hooks_ready=1
                ok "hookهای اختصاصی تمدید ذخیره و آزمایش شدند."
            else
                warn "ثبت hook اختصاصی ممکن نشد؛ از hookهای عمومی Certbot به‌عنوان روش جایگزین استفاده می‌شود."
            fi
        fi

        if [[ "$hooks_ready" -eq 0 ]]; then
            install_global_renewal_hooks
            hooks_ready=1
        fi

        if activate_https; then
            SSL_ACTIVE=1
            ok "HTTPS روی ${domain}:80 فعال شد."
            systemctl enable --now certbot.timer >/dev/null 2>&1 || true
            if [[ "$reconfigure_ok" -eq 0 && "$hooks_ready" -eq 1 ]]; then
                say "آزمایش تمدید خودکار (dry-run)..."
                if timeout 180 certbot renew --cert-name "$domain" --dry-run; then
                    ok "آزمایش تمدید خودکار موفق بود."
                else
                    warn "گواهی فعال است، اما آزمایش تمدید خودکار شکست خورد؛ گزارش را با certbot renew --cert-name ${domain} --dry-run بررسی کن."
                fi
            fi
        else
            warn "گواهی صادر شده اما فعال‌سازی HTTPS با خطا روبه‌رو شد؛ HTTP موقتاً فعال است."
        fi
    else
        SSL_ACTIVE=0
        activate_http || true
        warn "دامنه فعلاً با HTTP روی پورت 80 در دسترس است؛ پس از آماده شدن DNS دوباره نصب‌کننده را اجرا کن تا SSL تنظیم شود."
    fi
}

ask_domain() {
    local raw
    while true; do
        printf '\nساب‌دامین را برای تنظیم وارد کن (مثال: bot.example.com): '
        IFS= read -r raw
        raw="${raw,,}"
        DOMAIN="$(validate_domain "$raw" 2>/dev/null || true)"
        if [[ -n "$DOMAIN" ]]; then
            break
        fi
        warn "دامنه معتبر نیست. فقط نام دامنه کامل وارد کن؛ بدون https، پورت یا مسیر."
    done
    ok "دامنه انتخاب شد: ${DOMAIN}"
}

ask_migration_choice() {
    local choice
    while true; do
        printf '\nمی‌خواهی تمام محتویات پوشه /bot از سرور قبلی به همین سرور منتقل شود؟ [y/n]: '
        IFS= read -r choice
        case "${choice,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) warn "فقط y یا n وارد کن." ;;
        esac
    done
}

trust_remote_host_key() {
    local ip="$1"
    local known_hosts="/root/.ssh/known_hosts"
    local scan fingerprint answer
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch "$known_hosts"
    chmod 600 "$known_hosts"

    if ssh-keygen -F "$ip" -f "$known_hosts" >/dev/null 2>&1; then
        say "کلید میزبان SSH قبلاً ثبت شده؛ همان کلید قبلی بررسی می‌شود."
        return 0
    fi

    scan="$(ssh-keyscan -T 8 -p 22 "$ip" 2>/dev/null | awk '!/^#/ && NF >= 3')"
    [[ -n "$scan" ]] || die "دریافت کلید SSH از سرور قبلی ممکن نشد؛ انتقال انجام نشد."
    fingerprint="$(printf '%s\n' "$scan" | ssh-keygen -lf - 2>/dev/null || true)"
    printf '\nاثر انگشت تمام کلیدهای SSH دریافتی از سرور قبلی:\n%s\n' "${fingerprint:-نامشخص}"
    warn "برای امنیت، اثر انگشت‌ها را در صورت امکان از کنسول خود سرور قبلی بررسی کن؛ با y تمام کلیدهای نمایش‌داده‌شده پذیرفته می‌شوند."
    printf 'آیا این کلید را برای اتصال می‌پذیری؟ [y/N]: '
    IFS= read -r answer
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]] || die "کلید SSH تأیید نشد؛ انتقال لغو شد."
    printf '%s\n' "$scan" >> "$known_hosts"
    chmod 600 "$known_hosts"
}

migration_preflight_local() {
    if [[ -L "$WEBROOT" ]]; then
        die "/bot روی سرور مقصد یک symlink است؛ برای جلوگیری از نوشتن در مسیر نامشخص، انتقال متوقف شد."
    fi
    if [[ -e "$WEBROOT" && ! -d "$WEBROOT" ]]; then
        die "/bot وجود دارد اما پوشه نیست. انتقال انجام نشد."
    fi
    if [[ -d "$WEBROOT" ]] && find "$WEBROOT" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        die "پوشه /bot مقصد خالی نیست. برای جلوگیری از overwrite، هیچ فایلی تغییر نکرد. ابتدا از داده‌های مقصد بکاپ بگیر و /bot را خالی/جابجا کن، سپس دوباره اجرا کن."
    fi
    if mountpoint -q "$WEBROOT" 2>/dev/null; then
        die "/bot یک mount point است؛ انتقال اتمیک در این حالت انجام نمی‌شود."
    fi
}

migrate_bot() {
    local remote_bytes remote_count local_avail local_count ip choice
    say "انتقال پوشه /bot از سرور قبلی شروع می‌شود. سرور قبلی تغییر یا پاک نمی‌شود."
    warn "برای سازگاری کامل داده‌ها، بهتر است هنگام انتقال ربات‌ها و Cronهایی را که داخل /bot فایل می‌نویسند موقتاً متوقف کنی؛ فایل‌های در حال تغییر ممکن است باعث رد شدن انتقال شوند."

    printf '\nIPv4 سرور قبلی را وارد کن: '
    IFS= read -r ip
    validate_ipv4 "$ip" || die "IPv4 معتبر نیست؛ انتقال انجام نشد."
    REMOTE_IP="$ip"

    printf 'رمز عبور کاربر root روی سرور قبلی را وارد کن: '
    IFS= read -r -s REMOTE_PASSWORD
    printf '\n'
    [[ -n "$REMOTE_PASSWORD" ]] || die "رمز عبور خالی است؛ انتقال انجام نشد."

    migration_preflight_local
    local policy_created=0
    if [[ ! -e /usr/sbin/policy-rc.d ]]; then
        cat > /usr/sbin/policy-rc.d <<'POLICY'
#!/bin/sh
exit 101
POLICY
        chmod 755 /usr/sbin/policy-rc.d
        policy_created=1
        POLICY_FILE_CREATED=1
    fi
    if ! apt-get update; then
        [[ "$policy_created" -eq 1 ]] && { rm -f /usr/sbin/policy-rc.d; POLICY_FILE_CREATED=0; }
        die "به‌روزرسانی فهرست بسته‌ها برای ابزار انتقال ناموفق بود."
    fi
    APT_UPDATED=1
    if ! apt-get install -y --no-install-recommends sshpass pv tar openssh-client; then
        [[ "$policy_created" -eq 1 ]] && { rm -f /usr/sbin/policy-rc.d; POLICY_FILE_CREATED=0; }
        die "نصب ابزارهای انتقال ناموفق بود."
    fi
    [[ "$policy_created" -eq 1 ]] && { rm -f /usr/sbin/policy-rc.d; POLICY_FILE_CREATED=0; }
    tar --version 2>/dev/null | grep -q 'GNU tar' || die "روی مقصد GNU tar در دسترس نیست؛ انتقال امن و دقیق انجام نشد."
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    SSH_PASS_FILE="$(mktemp /run/bot-installer-sshpass.XXXXXX)"
    chmod 600 "$SSH_PASS_FILE"
    printf '%s\n' "$REMOTE_PASSWORD" > "$SSH_PASS_FILE"
    unset REMOTE_PASSWORD
    trust_remote_host_key "$REMOTE_IP"

    say "بررسی اتصال SSH و اندازه پوشه /bot روی سرور قبلی..."
    local info
    if ! info="$(sshpass -f "$SSH_PASS_FILE" ssh \
        -p 22 \
        -o ConnectTimeout=15 \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=2 \
        -o PreferredAuthentications=password,keyboard-interactive \
        -o PubkeyAuthentication=no \
        -o StrictHostKeyChecking=ask \
        "root@${REMOTE_IP}" \
        'set -eu; test -d /bot; test ! -L /bot; command -v tar >/dev/null; tar --version | grep -q "GNU tar"; printf "SIZE="; du -s --block-size=1 /bot | cut -f1; printf "COUNT="; find /bot -printf x | wc -c' 2>&1)"; then
        rm -f "$SSH_PASS_FILE"; SSH_PASS_FILE=""
        printf '%s\n' "$info" >&2
        die "اتصال به سرور قبلی ناموفق بود. ورود SSH با root و رمز عبور و GNU tar باید روی سرور قبلی فعال باشد؛ هیچ فایلی منتقل نشد."
    fi

    remote_bytes="$(printf '%s\n' "$info" | sed -n 's/^SIZE=//p' | tail -n1 | tr -d '\r')"
    remote_count="$(printf '%s\n' "$info" | sed -n 's/^COUNT=//p' | tail -n1 | tr -d '\r')"
    [[ "$remote_bytes" =~ ^[0-9]+$ && "$remote_count" =~ ^[0-9]+$ ]] || {
        rm -f "$SSH_PASS_FILE"; SSH_PASS_FILE=""
        printf '%s\n' "$info" >&2
        die "نتوانستم اندازه /bot را از سرور قبلی بخوانم؛ انتقال لغو شد."
    }

    local_avail="$(df -B1 --output=avail / | tail -n1 | tr -d ' ')"
    # Keep at least 8% plus 100 MiB headroom.
    local needed=$(( remote_bytes + remote_bytes / 12 + 104857600 ))
    say "حجم مصرفی مبدأ: $(numfmt --to=iec "$remote_bytes") | فایل‌ها/پوشه‌ها: $remote_count"
    say "فضای آزاد مقصد: $(numfmt --to=iec "$local_avail")"
    (( local_avail >= needed )) || {
        rm -f "$SSH_PASS_FILE"; SSH_PASS_FILE=""
        die "فضای دیسک مقصد کافی نیست. حداقل فضای موردنیاز تقریبی: $(numfmt --to=iec "$needed"). انتقال شروع نشد."
    }

    STAGE_DIR="$(mktemp -d '/bot-migration-stage.XXXXXX')"
    [[ "$(stat -c %d "$STAGE_DIR")" == "$(stat -c %d /)" ]] || {
        die "پوشه موقت و / روی یک filesystem نیستند؛ برای جلوگیری از کپی ناقص انتقال لغو شد."
    }

    say "در حال انتقال امن؛ رمز عبور نمایش داده نمی‌شود و فقط موقتاً در فایل محدودشده داخل /run نگهداری می‌شود؛ پس از اتصال حذف خواهد شد."
    local remote_tar='tar --numeric-owner --acls --xattrs --sparse -cpf - -C / bot'
    set +e
    set -o pipefail
    sshpass -f "$SSH_PASS_FILE" ssh \
        -p 22 \
        -o ConnectTimeout=15 \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        -o PreferredAuthentications=password,keyboard-interactive \
        -o PubkeyAuthentication=no \
        -o StrictHostKeyChecking=yes \
        "root@${REMOTE_IP}" "$remote_tar" \
      | pv -pterb -s "$remote_bytes" \
      | tar --numeric-owner --acls --xattrs --same-owner -xpf - -C "$STAGE_DIR"
    local pipe_rc=$?
    set -e
    rm -f "$SSH_PASS_FILE"
    SSH_PASS_FILE=""
    if [[ "$pipe_rc" -ne 0 ]]; then
        die "انتقال کامل نشد (کد خطا: $pipe_rc). فایل‌های موقت حذف می‌شوند و /bot مقصد دست‌نخورده می‌ماند."
    fi

    [[ -d "$STAGE_DIR/bot" ]] || die "آرشیو دریافتی پوشه bot نداشت؛ انتقال پذیرفته نشد."
    local_count="$(find "$STAGE_DIR/bot" -printf x | wc -c | tr -d ' ')"
    [[ "$local_count" == "$remote_count" ]] || die "تعداد آیتم‌ها برابر نیست (مبدأ: $remote_count، مقصد: $local_count). انتقال نهایی نشد."

    # The destination must still be empty. Never merge or overwrite existing user files.
    if [[ -d "$WEBROOT" ]] && find "$WEBROOT" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        die "در طول انتقال، /bot مقصد تغییر کرده است؛ نسخه دریافتی در مسیر موقت باقی نمی‌ماند و حذف خواهد شد."
    fi
    if [[ -d "$WEBROOT" ]]; then rmdir "$WEBROOT"; fi
    mv "$STAGE_DIR/bot" "$WEBROOT"
    MIGRATION_COMMITTED=1
    rmdir "$STAGE_DIR" 2>/dev/null || true
    STAGE_DIR=""

    ok "انتقال /bot کامل شد. تعداد آیتم‌های مبدأ و مقصد برابر است: $local_count"
    say "مالکیت عددی، permissionها، symlinkها، hardlinkها، ACL و xattrها تا حد پشتیبانی سیستم مقصد حفظ شدند."
    warn "دیتابیس MariaDB/MySQL، سرویس‌های systemd، Cronهای خارج از /bot، Docker و تنظیمات Xray منتقل نشده‌اند."
}

finish_message() {
    printf '\n\033[1;32m==================================================\033[0m\n'
    printf '\033[1;32m نصب‌کننده پایان یافت\033[0m\n'
    printf '\033[1;32m==================================================\033[0m\n'
    printf 'دامنه: %s\n' "$DOMAIN"
    printf 'مسیر سایت: %s\n' "$WEBROOT"
    if [[ "$SSL_ACTIVE" -eq 1 ]]; then
        printf 'آدرس HTTPS: https://%s:80/\n' "$DOMAIN"
    else
        printf 'آدرس فعلی: http://%s:80/ (گواهی SSL هنوز فعال نشده است)\n' "$DOMAIN"
    fi
    printf 'پورت 443 برای سرویس‌هایی مثل Xray آزاد نگه داشته شده است.\n'
    printf '\nبررسی وضعیت:\n'
    printf '  apache2ctl configtest\n'
    printf '  systemctl status apache2 --no-pager\n'
    printf '  certbot certificates\n'
    printf 'گزارش Apache: /var/log/apache2/%s-error.log\n' "$MANAGED_NAME"
    printf '\nتوجه: این نصب‌کننده فقط محتویات /bot را انتقال می‌دهد؛ برای کپی دیتابیس‌ها و سرویس‌های سیستم باید انتقال جداگانه طراحی شود.\n'
}

main() {
    clear 2>/dev/null || true
    printf '\033[1;35m%s\033[0m\n' "$APP_NAME"
    printf 'تنظیم Apache + HTTPS روی پورت 80 + انتقال اختیاری /bot\n'
    printf '%s\n' '--------------------------------------------------'

    need_root
    check_os

    # Refuse to proceed if TCP/80 is owned by a service other than Apache.
    local owner80
    owner80="$(port_owner 80 || true)"
    if [[ -n "$owner80" && "$owner80" != *apache2* ]]; then
        die "پورت 80 در اختیار سرویس دیگری است: $owner80 . ابتدا وضعیت آن را بررسی کن."
    fi

    local initial443_owner
    initial443_owner="$(port_owner 443 || true)"
    if [[ "$initial443_owner" == *apache2* ]]; then
        die "پورت 443 از قبل در اختیار Apache است؛ برای حفظ سرویس موجود ادامه ندادم."
    fi

    ask_domain
    local marker="/etc/${MANAGED_NAME}/domain"
    if [[ -f "$marker" ]]; then
        local old_domain
        old_domain="$(cat "$marker" 2>/dev/null || true)"
        [[ "$old_domain" == "$DOMAIN" ]] || die "این نصب‌کننده قبلاً برای ${old_domain} تنظیم شده است. برای جلوگیری از خراب شدن تمدید SSL دامنه قبلی، نصب یک دامنه متفاوت با همین نمونه پشتیبانی نمی‌شود."
    fi

    # Ask immediately after the domain, as requested. Migration completes before web setup.
    local do_migration=0
    if ask_migration_choice; then
        do_migration=1
        migrate_bot
    else
        ok "انتقال /bot رد شد؛ نصب وب‌سرور بدون کپی فایل‌های سرور قبلی ادامه می‌یابد."
    fi

    install_packages
    prepare_apache_ports "$initial443_owner"
    check_port80_and_vhosts

    # Apache may have just been installed; ensure it is enabled before issuing the cert.
    systemctl enable apache2 >/dev/null 2>&1 || true
    configure_domain_ssl "$DOMAIN"
    mkdir -p "/etc/${MANAGED_NAME}"
    printf '%s\n' "$DOMAIN" > "/etc/${MANAGED_NAME}/domain"
    chmod 600 "/etc/${MANAGED_NAME}/domain"

    if [[ "$do_migration" -eq 1 ]]; then
        ok "فایل‌های /bot منتقل شدند و وب‌سرور برای دامنه تنظیم شد."
    else
        ok "نصب وب‌سرور کامل شد؛ پوشه /bot آماده دریافت فایل‌های ربات است."
    fi

    # Check final Apache configuration without changing other services.
    apache2ctl configtest || die "پیکربندی Apache در بررسی نهایی خطا دارد؛ گزارش بالا را بررسی کن."
    systemctl reload apache2 2>/dev/null || systemctl restart apache2
    finish_message
}

main "$@"
