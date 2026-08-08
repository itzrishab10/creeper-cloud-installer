#!/usr/bin/env bash

# ============================================================
#              CREEPER CLOUD ALL-IN-ONE INSTALLER
#              KVM / QEMU / LIBVIRT VPS MANAGER
# ============================================================

set -Eeuo pipefail

VERSION="1.0.0"
BASE_DIR="/var/lib/creeper-cloud"
IMAGE_DIR="${BASE_DIR}/images"
CLOUD_DIR="${BASE_DIR}/cloud-init"

# ---------- COLORS ----------
RESET='\033[0m'
BOLD='\033[1m'
CYAN='\033[38;5;51m'
BLUE='\033[38;5;39m'
GREEN='\033[38;5;82m'
RED='\033[38;5;196m'
YELLOW='\033[38;5;226m'
WHITE='\033[38;5;255m'
GRAY='\033[38;5;245m'

trap 'echo -e "\n${RED}An error occurred on line $LINENO.${RESET}"' ERR

# ---------- BASIC ----------
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Run this installer as root.${RESET}"
    echo "Example:"
    echo "sudo bash install.sh"
    exit 1
fi

mkdir -p "$IMAGE_DIR" "$CLOUD_DIR"

pause() {
    echo
    read -rp "Press Enter to continue..."
}

header() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    printf "║              %-38s ║\n" "$1"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

success() {
    echo -e "${GREEN}[✓] $1${RESET}"
}

error() {
    echo -e "${RED}[✗] $1${RESET}"
}

info() {
    echo -e "${CYAN}[i] $1${RESET}"
}

warning() {
    echo -e "${YELLOW}[!] $1${RESET}"
}

# ============================================================
# SYSTEM
# ============================================================

detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "$PRETTY_NAME"
    else
        echo "Unknown"
    fi
}

system_info() {
    header "SYSTEM INFORMATION"

    echo -e "${WHITE}OS:${RESET}          $(detect_os)"
    echo -e "${WHITE}Kernel:${RESET}      $(uname -r)"
    echo -e "${WHITE}Architecture:${RESET} $(uname -m)"
    echo -e "${WHITE}Hostname:${RESET}    $(hostname)"

    echo
    echo -e "${WHITE}CPU:${RESET}"
    lscpu | grep -E 'Model name|CPU\(s\):' | head -2 || true

    echo
    echo -e "${WHITE}Memory:${RESET}"
    free -h

    echo
    echo -e "${WHITE}Disk:${RESET}"
    df -h /

    echo
    echo -e "${WHITE}KVM:${RESET}"
    if [[ -e /dev/kvm ]]; then
        success "/dev/kvm is available"
    else
        error "/dev/kvm is NOT available"
    fi

    pause
}

# ============================================================
# KVM CHECK
# ============================================================

check_kvm() {
    header "KVM SUPPORT CHECK"

    if [[ -e /dev/kvm ]]; then
        success "/dev/kvm exists"

        if [[ -r /dev/kvm && -w /dev/kvm ]]; then
            success "/dev/kvm is readable/writable"
        else
            warning "/dev/kvm permissions may need adjustment"
        fi
    else
        error "/dev/kvm does not exist"
        echo
        echo "Possible reasons:"
        echo "1. KVM is not supported"
        echo "2. Your VPS provider disabled nested virtualization"
        echo "3. You are inside a container"
    fi

    echo

    if command -v kvm-ok >/dev/null 2>&1; then
        kvm-ok || true
    elif grep -E 'vmx|svm' /proc/cpuinfo >/dev/null 2>&1; then
        success "CPU virtualization flags detected"
    else
        warning "CPU virtualization flags were not detected"
    fi

    pause
}

# ============================================================
# INSTALL KVM
# ============================================================

install_kvm() {
    header "INSTALL KVM / QEMU"

    source /etc/os-release

    case "${ID:-}" in
        ubuntu|debian)
            ;;
        *)
            error "This installer currently supports Ubuntu/Debian."
            pause
            return
            ;;
    esac

    info "Updating packages..."
    apt-get update

    info "Installing virtualization packages..."

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

    success "KVM/QEMU/libvirt installation completed."

    if [[ -e /dev/kvm ]]; then
        success "KVM hardware acceleration is available."
    else
        warning "/dev/kvm is unavailable."
        warning "Nested virtualization may be disabled."
    fi

    pause
}

# ============================================================
# LIBVIRT
# ============================================================

install_libvirt() {
    header "LIBVIRT SETUP"

    apt-get update

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        libvirt-daemon-system \
        libvirt-clients \
        virtinst \
        dnsmasq \
        bridge-utils

    systemctl enable --now libvirtd 2>/dev/null || \
    systemctl enable --now libvirt 2>/dev/null || true

    if virsh net-info default >/dev/null 2>&1; then
        virsh net-start default 2>/dev/null || true
        virsh net-autostart default 2>/dev/null || true
        success "Default libvirt network is active."
    fi

    success "libvirt is ready."

    pause
}

# ============================================================
# NETWORK
# ============================================================

network_info() {
    header "NETWORK INFORMATION"

    echo -e "${WHITE}Interfaces:${RESET}"
    ip -br addr

    echo
    echo -e "${WHITE}Libvirt Networks:${RESET}"
    virsh net-list --all 2>/dev/null || true

    echo
    echo -e "${WHITE}Default Network:${RESET}"
    virsh net-dumpxml default 2>/dev/null || true

    pause
}

# ============================================================
# OS IMAGE
# ============================================================

download_ubuntu() {
    local version="$1"

    mkdir -p "$IMAGE_DIR"

    case "$version" in
        24.04)
            URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
            FILE="$IMAGE_DIR/ubuntu-24.04.img"
            ;;
        22.04)
            URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
            FILE="$IMAGE_DIR/ubuntu-22.04.img"
            ;;
        *)
            error "Unsupported Ubuntu version."
            return 1
            ;;
    esac

    if [[ -f "$FILE" ]]; then
        success "Ubuntu $version image already exists."
        echo "$FILE"
        return 0
    fi

    info "Downloading Ubuntu $version cloud image..."
    curl -fL "$URL" -o "$FILE"

    success "Image downloaded:"
    echo "$FILE"
}

# ============================================================
# CREATE VPS
# ============================================================

create_vps() {
    header "CREATE KVM VPS"

    if [[ ! -e /dev/kvm ]]; then
        error "/dev/kvm is unavailable."
        warning "KVM VPS creation cannot continue."
        pause
        return
    fi

    if ! command -v virt-install >/dev/null 2>&1; then
        error "virt-install is not installed."
        echo "Run KVM installation first."
        pause
        return
    fi

    read -rp "VPS name: " VM_NAME

    if [[ -z "$VM_NAME" ]]; then
        error "VPS name cannot be empty."
        pause
        return
    fi

    if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
        error "A VPS with this name already exists."
        pause
        return
    fi

    read -rp "RAM in MB [2048]: " RAM
    RAM="${RAM:-2048}"

    read -rp "CPU cores [2]: " CPU
    CPU="${CPU:-2}"

    read -rp "Disk size in GB [20]: " DISK
    DISK="${DISK:-20}"

    read -rp "Ubuntu version [24.04]: " UBUNTU
    UBUNTU="${UBUNTU:-24.04}"

    read -rp "Username [ubuntu]: " VM_USER
    VM_USER="${VM_USER:-ubuntu}"

    echo
    echo -e "${WHITE}Set VPS password:${RESET}"
    read -rsp "Password: " VM_PASSWORD
    echo

    if [[ -z "$VM_PASSWORD" ]]; then
        error "Password cannot be empty."
        pause
        return
    fi

    IMAGE=$(download_ubuntu "$UBUNTU") || return 1

    # download_ubuntu prints messages, so get actual file path separately
    if [[ "$UBUNTU" == "24.04" ]]; then
        IMAGE="$IMAGE_DIR/ubuntu-24.04.img"
    else
        IMAGE="$IMAGE_DIR/ubuntu-22.04.img"
    fi

    VM_DIR="$BASE_DIR/vms/$VM_NAME"
    mkdir -p "$VM_DIR"

    DISK_FILE="$VM_DIR/$VM_NAME.qcow2"

    info "Creating $DISK GB virtual disk..."

    qemu-img create \
        -f qcow2 \
        -F qcow2 \
        -b "$IMAGE" \
        "$DISK_FILE" \
        "${DISK}G"

    META="$CLOUD_DIR/${VM_NAME}-meta-data"
    USER="$CLOUD_DIR/${VM_NAME}-user-data"

    cat > "$META" <<EOF
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF

    cat > "$USER" <<EOF
#cloud-config

users:
  - name: $VM_USER
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: '$VM_PASSWORD'

ssh_pwauth: true

package_update: true

packages:
  - openssh-server
  - curl
  - wget

runcmd:
  - systemctl enable ssh
  - systemctl restart ssh

final_message: "Creeper Cloud VPS ready."
EOF

    SEED="$VM_DIR/seed.iso"

    cloud-localds "$SEED" "$USER" "$META"

    info "Creating VPS..."

    virt-install \
        --name "$VM_NAME" \
        --memory "$RAM" \
        --vcpus "$CPU" \
        --disk "path=$DISK_FILE,format=qcow2,bus=virtio" \
        --disk "path=$SEED,device=cdrom" \
        --os-variant ubuntu24.04 \
        --network network=default,model=virtio \
        --graphics none \
        --console pty,target_type=serial \
        --import \
        --noautoconsole

    success "VPS created successfully."

    echo
    echo -e "${WHITE}VPS:${RESET}       $VM_NAME"
    echo -e "${WHITE}RAM:${RESET}       ${RAM} MB"
    echo -e "${WHITE}CPU:${RESET}       $CPU cores"
    echo -e "${WHITE}Disk:${RESET}      ${DISK} GB"
    echo -e "${WHITE}Username:${RESET}  $VM_USER"

    echo
    info "The VPS is booting."
    info "Use 'VPS Details' after a few seconds to see its IP."

    pause
}

# ============================================================
# VPS LIST
# ============================================================

list_vps() {
    header "VPS LIST"

    if ! command -v virsh >/dev/null 2>&1; then
        error "libvirt is not installed."
        pause
        return
    fi

    virsh list --all

    pause
}

# ============================================================
# SELECT VPS
# ============================================================

select_vps() {
    read -rp "VPS name: " VM_NAME

    if ! virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
        error "VPS '$VM_NAME' does not exist."
        return 1
    fi

    return 0
}

# ============================================================
# START
# ============================================================

start_vps() {
    header "START VPS"

    select_vps || {
        pause
        return
    }

    virsh start "$VM_NAME"

    success "$VM_NAME started."

    pause
}

# ============================================================
# STOP
# ============================================================

stop_vps() {
    header "STOP VPS"

    select_vps || {
        pause
        return
    }

    virsh shutdown "$VM_NAME" 2>/dev/null || true

    success "Shutdown command sent to $VM_NAME."

    pause
}

# ============================================================
# FORCE STOP
# ============================================================

force_stop_vps() {
    header "FORCE STOP VPS"

    select_vps || {
        pause
        return
    }

    read -rp "Force stop $VM_NAME? [y/N]: " CONFIRM

    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        virsh destroy "$VM_NAME"
        success "$VM_NAME stopped."
    fi

    pause
}

# ============================================================
# RESTART
# ============================================================

restart_vps() {
    header "RESTART VPS"

    select_vps || {
        pause
        return
    }

    virsh reboot "$VM_NAME" 2>/dev/null || {
        virsh destroy "$VM_NAME"
        virsh start "$VM_NAME"
    }

    success "$VM_NAME restarted."

    pause
}

# ============================================================
# VPS DETAILS
# ============================================================

vps_details() {
    header "VPS DETAILS"

    select_vps || {
        pause
        return
    }

    virsh dominfo "$VM_NAME"

    echo
    echo -e "${WHITE}IP addresses:${RESET}"

    virsh domifaddr "$VM_NAME" 2>/dev/null || true

    echo
    echo -e "${WHITE}Interfaces:${RESET}"

    virsh domiflist "$VM_NAME" 2>/dev/null || true

    pause
}

# ============================================================
# CONSOLE
# ============================================================

vps_console() {
    header "VPS CONSOLE"

    select_vps || {
        pause
        return
    }

    warning "Exit console with Ctrl+]"

    sleep 2

    virsh console "$VM_NAME"
}

# ============================================================
# DELETE VPS
# ============================================================

delete_vps() {
    header "DELETE VPS"

    select_vps || {
        pause
        return
    }

    echo
    warning "This will permanently delete:"
    echo "VPS: $VM_NAME"
    echo

    read -rp "Type DELETE to continue: " CONFIRM

    if [[ "$CONFIRM" != "DELETE" ]]; then
        echo "Cancelled."
        pause
        return
    fi

    virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" --nvram 2>/dev/null || \
    virsh undefine "$VM_NAME" 2>/dev/null || true

    rm -rf "$BASE_DIR/vms/$VM_NAME"
    rm -f "$CLOUD_DIR/${VM_NAME}-meta-data"
    rm -f "$CLOUD_DIR/${VM_NAME}-user-data"

    success "$VM_NAME deleted."

    pause
}

# ============================================================
# KVM MENU
# ============================================================

kvm_menu() {
    while true; do
        header "KVM VPS MANAGER"

        echo -e "${WHITE}"
        echo "  [1] Install KVM / QEMU"
        echo "  [2] Check KVM Support"
        echo "  [3] Install / Repair libvirt"
        echo "  [4] Network Information"
        echo "  [5] Download Ubuntu Image"
        echo "  [6] Create VPS"
        echo "  [7] List VPS"
        echo "  [8] Start VPS"
        echo "  [9] Stop VPS"
        echo " [10] Force Stop VPS"
        echo " [11] Restart VPS"
        echo " [12] VPS Details / IP"
        echo " [13] VPS Console"
        echo " [14] Delete VPS"
        echo " [15] Back"
        echo -e "${RESET}"

        read -rp "Select [1-15]: " OPTION

        case "$OPTION" in
            1) install_kvm ;;
            2) check_kvm ;;
            3) install_libvirt ;;
            4) network_info ;;
            5)
                header "DOWNLOAD UBUNTU IMAGE"
                read -rp "Ubuntu version [24.04]: " V
                V="${V:-24.04}"
                download_ubuntu "$V"
                pause
                ;;
            6) create_vps ;;
            7) list_vps ;;
            8) start_vps ;;
            9) stop_vps ;;
            10) force_stop_vps ;;
            11) restart_vps ;;
            12) vps_details ;;
            13) vps_console ;;
            14) delete_vps ;;
            15) return ;;
            *) error "Invalid option"; sleep 1 ;;
        esac
    done
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

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc

    chmod a+r /etc/apt/keyrings/docker.asc

    source /etc/os-release

    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable
EOF

    apt-get update

    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker

    success "Docker installed."

    docker --version

    pause
}

docker_menu() {
    while true; do
        header "DOCKER MANAGER"

        echo "[1] Install Docker"
        echo "[2] Docker Version"
        echo "[3] Docker Containers"
        echo "[4] Docker Images"
        echo "[5] Restart Docker"
        echo "[6] Back"

        echo
        read -rp "Select: " OPTION

        case "$OPTION" in
            1) install_docker ;;
            2)
                docker --version 2>/dev/null || error "Docker not installed."
                pause
                ;;
            3)
                docker ps -a 2>/dev/null || true
                pause
                ;;
            4)
                docker images 2>/dev/null || true
                pause
                ;;
            5)
                systemctl restart docker
                success "Docker restarted."
                pause
                ;;
            6) return ;;
            *) error "Invalid option"; sleep 1 ;;
        esac
    done
}

# ============================================================
# PTERODACTYL MENU
# ============================================================

pterodactyl_menu() {
    while true; do
        header "PTERODACTYL MANAGER"

        echo "[1] Panel Information"
        echo "[2] Wings Information"
        echo "[3] Restart Panel Services"
        echo "[4] Restart Wings"
        echo "[5] Panel Logs"
        echo "[6] Wings Logs"
        echo "[7] Back"

        echo
        read -rp "Select: " OPTION

        case "$OPTION" in
            1)
                echo
                echo "Pterodactyl Panel service:"
                systemctl status nginx --no-pager 2>/dev/null || true
                echo
                echo "PHP-FPM:"
                systemctl status php8.3-fpm --no-pager 2>/dev/null || \
                systemctl status php8.2-fpm --no-pager 2>/dev/null || true
                pause
                ;;
            2)
                systemctl status wings --no-pager 2>/dev/null || \
                    warning "Wings service is not installed."
                pause
                ;;
            3)
                systemctl restart nginx 2>/dev/null || true
                systemctl restart php8.3-fpm 2>/dev/null || true
                systemctl restart php8.2-fpm 2>/dev/null || true
                success "Panel services restarted."
                pause
                ;;
            4)
                systemctl restart wings 2>/dev/null || \
                    error "Wings service is not installed."
                pause
                ;;
            5)
                journalctl -u nginx -n 80 --no-pager 2>/dev/null || true
                pause
                ;;
            6)
                journalctl -u wings -n 80 --no-pager 2>/dev/null || true
                pause
                ;;
            7) return ;;
            *) error "Invalid option"; sleep 1 ;;
        esac
    done
}

# ============================================================
# SERVICES
# ============================================================

service_manager() {
    while true; do
        header "SERVICE MANAGER"

        echo "[1] Docker"
        echo "[2] libvirt"
        echo "[3] Nginx"
        echo "[4] Wings"
        echo "[5] Restart all"
        echo "[6] Back"

        echo
        read -rp "Select: " OPTION

        case "$OPTION" in
            1) systemctl restart docker; success "Docker restarted." ;;
            2)
                systemctl restart libvirtd 2>/dev/null || \
                systemctl restart libvirt 2>/dev/null || true
                success "libvirt restarted."
                ;;
            3) systemctl restart nginx 2>/dev/null || true; success "Nginx restarted." ;;
            4) systemctl restart wings 2>/dev/null || error "Wings not installed." ;;
            5)
                systemctl restart docker 2>/dev/null || true
                systemctl restart libvirtd 2>/dev/null || true
                systemctl restart nginx 2>/dev/null || true
                systemctl restart wings 2>/dev/null || true
                success "Services restarted."
                ;;
            6) return ;;
            *) error "Invalid option" ;;
        esac

        pause
    done
}

# ============================================================
# FIREWALL
# ============================================================

firewall_menu() {
    header "FIREWALL MANAGER"

    apt-get install -y ufw

    echo
    echo "[1] Allow SSH 22"
    echo "[2] Allow HTTP 80"
    echo "[3] Allow HTTPS 443"
    echo "[4] Allow Minecraft 25565"
    echo "[5] Show firewall"
    echo "[6] Back"

    echo
    read -rp "Select: " OPTION

    case "$OPTION" in
        1) ufw allow 22/tcp ;;
        2) ufw allow 80/tcp ;;
        3) ufw allow 443/tcp ;;
        4) ufw allow 25565/tcp ;;
        5) ufw status verbose ;;
        6) return ;;
    esac

    pause
}

# ============================================================
# MAIN MENU
# ============================================================

main_menu() {
    while true; do
        clear

        echo -e "${CYAN}"
        echo "╔══════════════════════════════════════════════════════╗"
        echo "║                                                      ║"
        echo "║              C R E E P E R   C L O U D              ║"
        echo "║                                                      ║"
        echo "║              ALL-IN-ONE INSTALLER                   ║"
        echo "║                   v${VERSION}                         ║"
        echo "║                                                      ║"
        echo "╠══════════════════════════════════════════════════════╣"
        echo "║                                                      ║"
        echo "║   [1]  KVM VPS Manager                               ║"
        echo "║   [2]  Pterodactyl Manager                           ║"
        echo "║   [3]  Docker Manager                                ║"
        echo "║   [4]  Service Manager                               ║"
        echo "║   [5]  Firewall Manager                              ║"
        echo "║   [6]  System Information                            ║"
        echo "║   [0]  Exit                                          ║"
        echo "║                                                      ║"
        echo "╚══════════════════════════════════════════════════════╝"
        echo -e "${RESET}"

        read -rp "Select an option: " OPTION

        case "$OPTION" in
            1) kvm_menu ;;
            2) pterodactyl_menu ;;
            3) docker_menu ;;
            4) service_manager ;;
            5) firewall_menu ;;
            6) system_info ;;
            0)
                echo
                success "Thanks for using Creeper Cloud Installer."
                exit 0
                ;;
            *)
                error "Invalid option."
                sleep 1
                ;;
        esac
    done
}

# ============================================================
# START
# ============================================================

main_menu
