#!/usr/bin/env bash

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════╗"
echo "║        CREEPER CLOUD INSTALLER           ║"
echo "║        Pterodactyl VPS Manager           ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run this installer as root.${NC}"
    exit 1
fi

pause() {
    echo
    read -rp "Press Enter to continue..."
}

install_docker() {
    echo -e "${CYAN}Installing Docker...${NC}"

    apt-get update
    apt-get install -y ca-certificates curl

    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc

    chmod a+r /etc/apt/keyrings/docker.asc

    . /etc/os-release

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update

    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    echo -e "${GREEN}Docker installed successfully.${NC}"
}

check_system() {
    echo -e "${CYAN}Checking system...${NC}"

    echo
    echo "OS:"
    cat /etc/os-release | grep PRETTY_NAME || true

    echo
    echo "Kernel:"
    uname -r

    echo
    echo "Architecture:"
    dpkg --print-architecture

    echo
    echo "Memory:"
    free -h

    echo
    echo "Disk:"
    df -h /

    pause
}

docker_status() {
    if command -v docker >/dev/null 2>&1; then
        echo -e "${GREEN}Docker is installed.${NC}"
        docker --version
        systemctl is-active --quiet docker \
            && echo -e "${GREEN}Docker service: RUNNING${NC}" \
            || echo -e "${RED}Docker service: NOT RUNNING${NC}"
    else
        echo -e "${YELLOW}Docker is not installed.${NC}"
    fi

    pause
}

restart_services() {
    echo -e "${CYAN}Restarting common services...${NC}"

    systemctl restart docker 2>/dev/null || true
    systemctl restart nginx 2>/dev/null || true
    systemctl restart wings 2>/dev/null || true
    systemctl restart php8.3-fpm 2>/dev/null || true
    systemctl restart php8.2-fpm 2>/dev/null || true

    echo -e "${GREEN}Restart completed.${NC}"

    pause
}

show_menu() {
    while true; do
        clear

        echo -e "${CYAN}"
        echo "╔══════════════════════════════════════════╗"
        echo "║        CREEPER CLOUD INSTALLER           ║"
        echo "╠══════════════════════════════════════════╣"
        echo "║  1. System Information                   ║"
        echo "║  2. Install Docker                       ║"
        echo "║  3. Docker Status                        ║"
        echo "║  4. Restart Services                     ║"
        echo "║  5. Pterodactyl Panel Setup              ║"
        echo "║  6. Wings Setup                          ║"
        echo "║  7. Exit                                 ║"
        echo "╚══════════════════════════════════════════╝"
        echo -e "${NC}"

        read -rp "Select an option [1-7]: " choice

        case "$choice" in
            1)
                check_system
                ;;
            2)
                install_docker
                pause
                ;;
            3)
                docker_status
                ;;
            4)
                restart_services
                ;;
            5)
                echo
                echo -e "${YELLOW}Pterodactyl Panel setup:${NC}"
                echo
                echo "Use the official Pterodactyl Panel installation documentation."
                echo "https://pterodactyl.io/project/introduction.html"
                echo
                pause
                ;;
            6)
                echo
                echo -e "${YELLOW}Wings setup:${NC}"
                echo
                echo "Wings should be configured from your Pterodactyl Panel"
                echo "Node configuration after Panel installation."
                echo
                pause
                ;;
            7)
                echo -e "${GREEN}Goodbye.${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option.${NC}"
                sleep 2
                ;;
        esac
    done
}

show_menu
