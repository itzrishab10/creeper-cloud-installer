#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
#              CREEPER CLOUD ALL-IN-ONE
#        KVM + PTERODACTYL + DOCKER + CLOUDFLARE
# ============================================================

VERSION="2.0"
PTERO_DIR="/var/www/pterodactyl"
BASE_DIR="/var/lib/creeper-cloud"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Run this script as root.${NC}"
    exit 1
fi

pause() {
    echo
    read -rp "Press Enter to continue..."
}

header() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    printf "║ %-52s ║\n" "$1"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

ok() {
    echo -e "${GREEN}[✓] $1${NC}"
}

fail() {
    echo -e "${RED}[✗] $1${NC}"
}

info() {
    echo -e "${CYAN}[i] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[!] $1${NC}"
}

# ============================================================
# OS CHECK
# ============================================================

check_os() {

    if [[ ! -f /etc/os-release ]]; then
        fail "Cannot detect operating system."
        exit 1
    fi

    source /etc/os-release

    case "$ID" in
        ubuntu|debian)
            ;;
        *)
            fail "This installer supports Ubuntu/Debian."
            exit 1
            ;;
    esac
}

# ============================================================
# COMMON PACKAGES
# ============================================================

install_common() {

    apt-get update

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl \
        wget \
        git \
        unzip \
        tar \
        ca-certificates \
        gnupg \
        lsb-release \
        software-properties-common \
        apt-transport-https \
        sudo \
        cron \
        nano \
        curl
}

# ============================================================
# PHP 8.3
# ============================================================

install_php() {

    info "Installing PHP 8.3..."

    if [[ "$ID" == "ubuntu" ]]; then

        if [[ "$VERSION_ID" == "22.04" ]]; then
            add-apt-repository -y ppa:ondrej/php
            apt-get update
        fi

    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        php8.3 \
        php8.3-cli \
        php8.3-common \
        php8.3-gd \
        php8.3-mysql \
        php8.3-mbstring \
        php8.3-bcmath \
        php8.3-xml \
        php8.3-fpm \
        php8.3-curl \
        php8.3-zip

    systemctl enable --now php8.3-fpm

    ok "PHP 8.3 installed."
}

# ============================================================
# DATABASE
# ============================================================

install_database() {

    info "Installing MariaDB..."

    DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server

    systemctl enable --now mariadb

    ok "MariaDB installed."
}

# ============================================================
# REDIS
# ============================================================

install_redis() {

    info "Installing Redis..."

    DEBIAN_FRONTEND=noninteractive apt-get install -y redis-server

    systemctl enable --now redis-server

    ok "Redis installed."
}

# ============================================================
# COMPOSER
# ============================================================

install_composer() {

    if command -v composer >/dev/null 2>&1; then
        ok "Composer already installed."
        return
    fi

    info "Installing Composer..."

    EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"

    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"

    ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

    if [[ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]]; then
        rm -f composer-setup.php
        fail "Composer installer checksum failed."
        return 1
    fi

    php composer-setup.php \
        --install-dir=/usr/local/bin \
        --filename=composer

    rm -f composer-setup.php

    ok "Composer installed."
}

# ============================================================
# NGINX
# ============================================================

install_nginx() {

    info "Installing Nginx..."

    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx

    systemctl enable --now nginx

    ok "Nginx installed."
}

# ============================================================
# DOCKER
# ============================================================

install_docker() {

    header "DOCKER INSTALLER"

    apt-get update

    apt-get install -y \
        ca-certificates \
        curl \
        gnupg

    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL \
        https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc

    chmod a+r /etc/apt/keyrings/docker.asc

    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
    fi

    if [[ "$ID" == "ubuntu" ]]; then

        cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable
EOF

    else

        rm -f /etc/apt/sources.list.d/docker.list

        cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable
EOF

    fi

    apt-get update

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker

    ok "Docker installed."

    docker --version

    pause
}

# ============================================================
# PANEL DATABASE
# ============================================================

create_panel_database() {

    header "PTERODACTYL DATABASE"

    DB_NAME="panel"
    DB_USER="pterodactyl"

    DB_PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"

    info "Creating database..."

    mariadb <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF

    cat > /root/creeper-cloud-pterodactyl-db.txt <<EOF
Pterodactyl Database
====================

Database: ${DB_NAME}
Username: ${DB_USER}
Password: ${DB_PASS}
Host: 127.0.0.1
Port: 3306
EOF

    chmod 600 /root/creeper-cloud-pterodactyl-db.txt

    ok "Database created."

    echo
    echo "Database credentials saved to:"
    echo "/root/creeper-cloud-pterodactyl-db.txt"

    pause
}

# ============================================================
# DOWNLOAD PANEL
# ============================================================

download_panel() {

    header "PTERODACTYL PANEL"

    mkdir -p "$PTERO_DIR"

    cd "$PTERO_DIR"

    info "Downloading latest Pterodactyl Panel..."

    curl -fL \
        https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz \
        -o panel.tar.gz

    tar -xzf panel.tar.gz

    rm -f panel.tar.gz

    chmod -R 755 storage bootstrap/cache

    ok "Panel files installed."
}

# ============================================================
# PANEL COMPOSER
# ============================================================

panel_composer() {

    header "PANEL DEPENDENCIES"

    cd "$PTERO_DIR"

    COMPOSER_ALLOW_SUPERUSER=1 \
        composer install \
        --no-dev \
        --optimize-autoloader

    ok "Panel dependencies installed."
}

# ============================================================
# PANEL ENVIRONMENT
# ============================================================

configure_panel() {

    header "PANEL CONFIGURATION"

    cd "$PTERO_DIR"

    cp -n .env.example .env

    php artisan key:generate --force

    echo
    echo -e "${WHITE}Panel URL${NC}"
    read -rp "Enter panel URL (example: https://panel.example.com): " PANEL_URL

    if [[ -z "$PANEL_URL" ]]; then
        PANEL_URL="http://localhost"
    fi

    sed -i "s#^APP_URL=.*#APP_URL=${PANEL_URL}#" .env

    sed -i "s#^DB_DATABASE=.*#DB_DATABASE=panel#" .env
    sed -i "s#^DB_USERNAME=.*#DB_USERNAME=pterodactyl#" .env
    sed -i "s#^DB_PASSWORD=.*#DB_PASSWORD=${DB_PASS}#" .env

    php artisan migrate --seed --force

    ok "Panel environment configured."

    echo
    info "Now create your first administrator."
    echo

    php artisan p:user:make

    ok "Administrator created."

    chown -R www-data:www-data \
        "$PTERO_DIR/storage" \
        "$PTERO_DIR/bootstrap/cache"

    chown -R www-data:www-data "$PTERO_DIR"

    pause
}

# ============================================================
# QUEUE WORKER
# ============================================================

install_queue_worker() {

    header "PTERODACTYL QUEUE WORKER"

    cat > /etc/systemd/system/pteroq.service <<'EOF'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now pteroq.service

    ok "Queue worker enabled."

    pause
}

# ============================================================
# NGINX PANEL CONFIG
# ============================================================

configure_nginx() {

    header "NGINX CONFIGURATION"

    read -rp "Panel domain (example: panel.example.com): " DOMAIN

    if [[ -z "$DOMAIN" ]]; then
        fail "Domain cannot be empty."
        pause
        return
    fi

    rm -f /etc/nginx/sites-enabled/default

    cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    root /var/www/pterodactyl/public;

    index index.php;

    charset utf-8;

    client_max_body_size 100m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico {
        access_log off;
        log_not_found off;
    }

    location = /robots.txt {
        access_log off;
        log_not_found off;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

    ln -sf \
        /etc/nginx/sites-available/pterodactyl.conf \
        /etc/nginx/sites-enabled/pterodactyl.conf

    nginx -t

    systemctl restart nginx

    ok "Nginx configured."

    pause
}

# ============================================================
# SSL
# ============================================================

install_ssl() {

    header "SSL / HTTPS"

    read -rp "Domain: " DOMAIN

    if [[ -z "$DOMAIN" ]]; then
        fail "Domain required."
        pause
        return
    fi

    read -rp "Email: " EMAIL

    apt-get update

    apt-get install -y \
        certbot \
        python3-certbot-nginx

    certbot --nginx \
        -d "$DOMAIN" \
        --non-interactive \
        --agree-tos \
        -m "$EMAIL" \
        --redirect

    ok "SSL configured."

    pause
}

# ============================================================
# FULL PTERODACTYL INSTALL
# ============================================================

install_panel() {

    header "PTERODACTYL PANEL INSTALLER"

    warning "This will install/update Panel dependencies."

    echo
    read -rp "Continue? [y/N]: " CONFIRM

    [[ "$CONFIRM" =~ ^[Yy]$ ]] || return

    install_common
    install_php
    install_database
    install_redis
    install_nginx
    install_composer

    create_panel_database
    download_panel
    panel_composer
    configure_panel
    install_queue_worker
    configure_nginx

    echo
    ok "Pterodactyl Panel installation completed."

    echo
    echo "Next:"
    echo "1. Point your DNS A record to this VPS."
    echo "2. Run SSL from the installer."
    echo "3. Create a Node in the Pterodactyl admin panel."
    echo "4. Install/configure Wings on the node."

    pause
}

# ============================================================
# WINGS
# ============================================================

install_wings() {

    header "PTERODACTYL WINGS INSTALLER"

    info "Installing Docker..."

    install_docker

    info "Installing Wings dependencies..."

    mkdir -p /etc/pterodactyl

    ARCH="$(dpkg --print-architecture)"

    case "$ARCH" in
        amd64)
            WINGS_ARCH="amd64"
            ;;
        arm64)
            WINGS_ARCH="arm64"
            ;;
        armhf)
            WINGS_ARCH="arm"
            ;;
        *)
            fail "Unsupported architecture: $ARCH"
            pause
            return
            ;;
    esac

    info "Downloading latest Wings..."

    curl -L \
        "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${WINGS_ARCH}" \
        -o /usr/local/bin/wings

    chmod u+x /usr/local/bin/wings

    cat > /etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    mkdir -p /var/run/wings

    systemctl daemon-reload
    systemctl enable wings

    ok "Wings binary installed."

    echo
    echo -e "${YELLOW}"
    echo "======================================================"
    echo " IMPORTANT: NODE CONFIGURATION REQUIRED"
    echo "======================================================"
    echo -e "${NC}"

    echo "1. Open your Pterodactyl Panel."
    echo "2. Admin → Nodes → Create New."
    echo "3. Set this VPS's FQDN."
    echo "4. Open the Configuration tab."
    echo "5. Copy the generated config.yml."
    echo
    echo "Paste the complete config.yml below."
    echo "Type END on a new line when finished."
    echo

    CONFIG_FILE="/etc/pterodactyl/config.yml"
    TMP_CONFIG="/tmp/pterodactyl-config.yml"

    : > "$TMP_CONFIG"

    while IFS= read -r line; do
        [[ "$line" == "END" ]] && break
        echo "$line" >> "$TMP_CONFIG"
    done

    if [[ ! -s "$TMP_CONFIG" ]]; then
        warn "No config supplied."
        warn "Wings is installed but not configured."
        rm -f "$TMP_CONFIG"
        pause
        return
    fi

    mv "$TMP_CONFIG" "$CONFIG_FILE"

    chmod 600 "$CONFIG_FILE"

    systemctl restart wings

    sleep 2

    if systemctl is-active --quiet wings; then
        ok "Wings is RUNNING."
    else
        fail "Wings failed to start."
        echo
        journalctl -u wings -n 40 --no-pager || true
    fi

    pause
}

# ============================================================
# PANEL + WINGS
# ============================================================

install_panel_wings() {

    header "PANEL + WINGS"

    echo
    warning "Panel will be installed first."
    echo "After Panel installation you will create a Node."
    echo "Then Wings will be installed and configured."
    echo

    read -rp "Continue? [y/N]: " CONFIRM

    [[ "$CONFIRM" =~ ^[Yy]$ ]] || return

    install_panel

    echo
    echo "Panel installation is complete."
    echo
    read -rp "Install Wings now? [y/N]: " WINGS_CONFIRM

    if [[ "$WINGS_CONFIRM" =~ ^[Yy]$ ]]; then
        install_wings
    fi
}

# ============================================================
# CLOUDFLARE
# ============================================================

install_cloudflare() {

    header "CLOUDFLARE TUNNEL"

    ARCH="$(dpkg --print-architecture)"

    case "$ARCH" in
        amd64) CF_ARCH="amd64" ;;
        arm64) CF_ARCH="arm64" ;;
        armhf) CF_ARCH="arm" ;;
        *)
            fail "Unsupported architecture."
            pause
            return
            ;;
    esac

    info "Installing cloudflared..."

    curl -L \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}.deb" \
        -o /tmp/cloudflared.deb

    dpkg -i /tmp/cloudflared.deb || apt-get install -f -y

    rm -f /tmp/cloudflared.deb

    ok "cloudflared installed."

    echo
    echo "Paste your Cloudflare Tunnel token."
    echo "Input will be hidden."
    echo

    read -rsp "Tunnel Token: " CF_TOKEN
    echo

    if [[ -z "$CF_TOKEN" ]]; then
        fail "Token cannot be empty."
        pause
        return
    fi

    cloudflared service uninstall 2>/dev/null || true

    cloudflared service install "$CF_TOKEN"

    systemctl enable cloudflared
    systemctl restart cloudflared

    sleep 3

    if systemctl is-active --quiet cloudflared; then
        ok "Cloudflare Tunnel is running."
    else
        fail "Cloudflare Tunnel failed."
        journalctl -u cloudflared -n 30 --no-pager || true
    fi

    pause
}

# ============================================================
# PTERODACTYL MENU
# ============================================================

pterodactyl_menu() {

    while true; do

        header "PTERODACTYL INSTALLER (NOT WORKING)"

        echo
        echo "  [1] Install Panel"
        echo "  [2] Install Wings"
        echo "  [3] Install Panel + Wings"
        echo "  [4] Configure Nginx"
        echo "  [5] Install SSL"
        echo "  [6] Restart Panel"
        echo "  [7] Restart Wings"
        echo "  [8] Panel Logs"
        echo "  [9] Wings Logs"
        echo " [10] Panel Info"
        echo " [11] Back"
        echo

        read -rp "Select [1-11]: " OPTION

        case "$OPTION" in

            1)
                install_panel
                ;;

            2)
                install_wings
                ;;

            3)
                install_panel_wings
                ;;

            4)
                configure_nginx
                ;;

            5)
                install_ssl
                ;;

            6)
                systemctl restart nginx 2>/dev/null || true
                systemctl restart php8.3-fpm 2>/dev/null || true
                systemctl restart pteroq 2>/dev/null || true
                ok "Panel services restarted."
                pause
                ;;

            7)
                systemctl restart wings 2>/dev/null || true
                ok "Wings restarted."
                pause
                ;;

            8)
                journalctl -u pteroq -n 80 --no-pager 2>/dev/null || true
                pause
                ;;

            9)
                journalctl -u wings -n 80 --no-pager 2>/dev/null || true
                pause
                ;;

            10)
                if [[ -d "$PTERO_DIR" ]]; then
                    cd "$PTERO_DIR"
                    php artisan p:info 2>/dev/null || true
                else
                    fail "Panel is not installed."
                fi
                pause
                ;;

            11)
                return
                ;;

            *)
                fail "Invalid option."
                sleep 1
                ;;
        esac
    done
}

# ============================================================
# KVM
# ============================================================

install_kvm() {

    header "KVM / QEMU INSTALLER"

    apt-get update

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        qemu-kvm \
        qemu-utils \
        libvirt-daemon-system \
        libvirt-clients \
        virtinst \
        cloud-image-utils \
        bridge-utils \
        dnsmasq \
        ovmf \
        cpu-checker

    systemctl enable --now libvirtd 2>/dev/null || \
    systemctl enable --now libvirt 2>/dev/null || true

    virsh net-start default 2>/dev/null || true
    virsh net-autostart default 2>/dev/null || true

    if [[ -e /dev/kvm ]]; then
        ok "KVM is available."
    else
        warn "KVM installed but /dev/kvm is unavailable."
        warn "Nested virtualization may be disabled."
    fi

    ok "KVM/QEMU installation completed."

    pause
}

kvm_menu() {

    while true; do

        header "KVM VPS"

        echo
        echo "[1] Install KVM / QEMU"
        echo "[2] Check KVM"
        echo "[3] Install libvirt"
        echo "[4] List VPS"
        echo "[5] Back"
        echo

        read -rp "Select: " OPTION

        case "$OPTION" in
            1)
                install_kvm
                ;;
            2)
                if [[ -e /dev/kvm ]]; then
                    ok "/dev/kvm exists."
                else
                    fail "/dev/kvm does not exist."
                fi
                pause
                ;;
            3)
                install_kvm
                ;;
            4)
                virsh list --all 2>/dev/null || \
                    fail "libvirt not installed."
                pause
                ;;
            5)
                return
                ;;
            *)
                fail "Invalid option."
                sleep 1
                ;;
        esac
    done
}

# ============================================================
# FIREWALL
# ============================================================

firewall_menu() {

    header "FIREWALL"

    apt-get install -y ufw

    echo
    echo "[1] Allow SSH"
    echo "[2] Allow HTTP"
    echo "[3] Allow HTTPS"
    echo "[4] Allow Minecraft"
    echo "[5] Show Status"
    echo "[6] Back"
    echo

    read -rp "Select: " OPTION

    case "$OPTION" in
        1)
            ufw allow 22/tcp
            ;;
        2)
            ufw allow 80/tcp
            ;;
        3)
            ufw allow 443/tcp
            ;;
        4)
            ufw allow 25565/tcp
            ;;
        5)
            ufw status verbose
            ;;
        6)
            return
            ;;
    esac

    pause
}

# ============================================================
# SERVICE MANAGER
# ============================================================

service_manager() {

    while true; do

        header "SERVICE MANAGER"

        echo
        echo "[1] Docker"
        echo "[2] Nginx"
        echo "[3] MariaDB"
        echo "[4] Redis"
        echo "[5] Pterodactyl Queue"
        echo "[6] Wings"
        echo "[7] Cloudflared"
        echo "[8] Restart All"
        echo "[9] Back"
        echo

        read -rp "Select: " OPTION

        case "$OPTION" in
            1) systemctl restart docker ;;
            2) systemctl restart nginx ;;
            3) systemctl restart mariadb ;;
            4) systemctl restart redis-server ;;
            5) systemctl restart pteroq ;;
            6) systemctl restart wings ;;
            7) systemctl restart cloudflared ;;
            8)
                systemctl restart docker 2>/dev/null || true
                systemctl restart nginx 2>/dev/null || true
                systemctl restart mariadb 2>/dev/null || true
                systemctl restart redis-server 2>/dev/null || true
                systemctl restart pteroq 2>/dev/null || true
                systemctl restart wings 2>/dev/null || true
                systemctl restart cloudflared 2>/dev/null || true
                ;;
            9)
                return
                ;;
            *)
                fail "Invalid option."
                ;;
        esac

        ok "Done."
        pause
    done
}

# ============================================================
# MAIN MENU
# ============================================================

main_menu() {

    check_os

    while true; do

        clear

        echo -e "${CYAN}"
        echo "╔══════════════════════════════════════════════════════╗"
        echo "║                                                      ║"
        echo "║             C R E E P E R   C L O U D              ║"
        echo "║                                                      ║"
        echo "║              ALL-IN-ONE INSTALLER                   ║"
        echo "║                    v${VERSION}                        ║"
        echo "║                                                      ║"
        echo "╠══════════════════════════════════════════════════════╣"
        echo "║                                                      ║"
        echo "║   [1]  KVM VPS Installer                             ║"
        echo "║   [2]  Pterodactyl Installer                         ║"
        echo "║   [3]  Docker Installer                              ║"
        echo "║   [4]  Cloudflare Tunnel                             ║"
        echo "║   [5]  Service Manager                               ║"
        echo "║   [6]  Firewall                                      ║"
        echo "║   [7]  System Information                            ║"
        echo "║                                                      ║"
        echo "║   [0]  Exit                                          ║"
        echo "║                                                      ║"
        echo "╚══════════════════════════════════════════════════════╝"
        echo -e "${NC}"

        read -rp "Select an option: " OPTION

        case "$OPTION" in
            1)
                kvm_menu
                ;;
            2)
                pterodactyl_menu
                ;;
            3)
                install_docker
                ;;
            4)
                install_cloudflare
                ;;
            5)
                service_manager
                ;;
            6)
                firewall_menu
                ;;
            7)
                header "SYSTEM INFORMATION"
                hostnamectl 2>/dev/null || true
                echo
                free -h
                echo
                df -h /
                echo
                uname -a
                pause
                ;;
            0)
                echo
                ok "Creeper Cloud installer closed."
                exit 0
                ;;
            *)
                fail "Invalid option."
                sleep 1
                ;;
        esac
    done
}

main_menu
