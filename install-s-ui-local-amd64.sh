#!/usr/bin/env bash

set -Eeuo pipefail

readonly ARCHIVE_URL="https://github.com/yihangliu612/My-UI/releases/download/s-ui/s-ui-linux-amd64.tar.gz"
readonly EXPECTED_SHA256="6413A8D7A473E6D8A582234571FE7264524CDEF860D82C19F65177BF7735290C"
readonly INSTALL_DIR="/usr/local/s-ui"
readonly SERVICE_FILE="/etc/systemd/system/s-ui.service"
readonly CONTROL_COMMAND="/usr/bin/s-ui"

ARCHIVE_PATH="${1:-}"
DOWNLOADED_ARCHIVE=""
TEMP_DIR=""
FRESH_INSTALL="yes"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

info() {
    echo -e "${green}[信息]${plain} $*"
}

warn() {
    echo -e "${yellow}[注意]${plain} $*" >&2
}

fatal() {
    echo -e "${red}[错误]${plain} $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi

    if [[ -n "$DOWNLOADED_ARCHIVE" && -f "$DOWNLOADED_ARCHIVE" ]]; then
        rm -f -- "$DOWNLOADED_ARCHIVE"
    fi
}

trap cleanup EXIT

normalize_path() {
    local value="$1"
    value="/${value#/}"
    [[ "$value" == */ ]] || value="${value}/"
    printf '%s' "$value"
}

random_hash_256() {
    head -c 64 /dev/urandom | sha256sum | awk '{print $1}'
}

random_path_256() {
    printf '/%s/' "$(random_hash_256)"
}

read_port() {
    local prompt="$1"
    local value
    local numeric

    while true; do
        read -r -p "$prompt" value

        if [[ ! "$value" =~ ^[0-9]+$ ]]; then
            warn "端口必须是 1 到 65535 之间的整数，不能留空。"
            continue
        fi

        numeric=$((10#$value))

        if (( numeric < 1 || numeric > 65535 )); then
            warn "端口超出范围，请输入 1 到 65535。"
            continue
        fi

        printf '%s' "$numeric"
        return
    done
}

require_root() {
    [[ "$EUID" -eq 0 ]] || fatal "请使用 root 用户执行此脚本。"
}

check_system() {
    [[ -r /etc/os-release ]] || fatal "无法读取 /etc/os-release。"

    # shellcheck disable=SC1091
    source /etc/os-release

    [[ "${ID:-}" == "debian" ]] || warn "当前系统是 ${ID:-unknown}，本脚本按 Debian 12 编写。"
    [[ "${VERSION_ID:-}" == "12" ]] || warn "当前 Debian 版本是 ${VERSION_ID:-unknown}，目标版本是 Debian 12。"

    case "$(uname -m)" in
        x86_64 | amd64)
            ;;
        *)
            fatal "当前 CPU 架构是 $(uname -m)，但上传的是 amd64 安装包。"
            ;;
    esac

    info "系统：${PRETTY_NAME:-Debian}"
    info "架构：amd64"
}

install_dependencies() {
    info "安装基础依赖..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl tar coreutils
}

download_archive() {
    if [[ -n "$ARCHIVE_PATH" ]]; then
        [[ -f "$ARCHIVE_PATH" ]] || fatal "找不到指定的安装包：$ARCHIVE_PATH"
        info "使用指定的本地安装包：$ARCHIVE_PATH"
        return
    fi

    ARCHIVE_PATH="$(mktemp /tmp/s-ui-linux-amd64.XXXXXX.tar.gz)"
    DOWNLOADED_ARCHIVE="$ARCHIVE_PATH"

    info "从 GitHub Release 下载 S-UI 1.4.2 安装包..."
    if ! curl \
        --fail \
        --location \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 15 \
        --output "$ARCHIVE_PATH" \
        "$ARCHIVE_URL"; then
        fatal "安装包下载失败：$ARCHIVE_URL"
    fi

    info "安装包下载完成。"
}

verify_archive() {
    [[ -f "$ARCHIVE_PATH" ]] || fatal "找不到安装包：$ARCHIVE_PATH"

    local actual_sha256
    actual_sha256="$(sha256sum "$ARCHIVE_PATH" | awk '{print toupper($1)}')"

    if [[ "$actual_sha256" != "$EXPECTED_SHA256" ]]; then
        fatal "安装包校验失败。实际 SHA-256：$actual_sha256"
    fi

    info "安装包 SHA-256 校验通过。"
}

extract_archive() {
    TEMP_DIR="$(mktemp -d /tmp/s-ui-local-install.XXXXXX)"
    info "解压安装包到临时目录：$TEMP_DIR"
    tar -xzf "$ARCHIVE_PATH" -C "$TEMP_DIR"

    [[ -x "$TEMP_DIR/s-ui/sui" ]] || fatal "压缩包中缺少可执行文件 s-ui/sui。"
    [[ -f "$TEMP_DIR/s-ui/s-ui.sh" ]] || fatal "压缩包中缺少管理脚本 s-ui/s-ui.sh。"
    [[ -f "$TEMP_DIR/s-ui/s-ui.service" ]] || fatal "压缩包中缺少 systemd 服务文件。"
}

install_files() {
    [[ -f "$INSTALL_DIR/db/s-ui.db" ]] && FRESH_INSTALL="no"

    if systemctl is-active --quiet s-ui 2>/dev/null; then
        info "停止现有 s-ui 服务..."
        systemctl stop s-ui
    fi

    install -d -m 0755 "$INSTALL_DIR"
    install -m 0755 "$TEMP_DIR/s-ui/sui" "$INSTALL_DIR/sui"
    install -m 0755 "$TEMP_DIR/s-ui/s-ui.sh" "$INSTALL_DIR/s-ui.sh"
    install -m 0755 "$TEMP_DIR/s-ui/s-ui.sh" "$CONTROL_COMMAND"
    install -m 0644 "$TEMP_DIR/s-ui/s-ui.service" "$SERVICE_FILE"

    if [[ "$FRESH_INSTALL" == "no" ]]; then
        info "检测到现有数据库，已保留：$INSTALL_DIR/db/s-ui.db"
    fi
}

configure_s_ui() {
    info "执行数据库迁移..."
    "$INSTALL_DIR/sui" migrate

    local configure_default="y"
    [[ "$FRESH_INSTALL" == "no" ]] && configure_default="n"

    local configure_answer
    read -r -p "现在配置面板、订阅和管理员信息吗？[y/n，默认 $configure_default]：" configure_answer
    configure_answer="${configure_answer:-$configure_default}"

    if [[ ! "$configure_answer" =~ ^[Yy]$ ]]; then
        warn "跳过配置。稍后可运行 s-ui 进入管理菜单。"
        return
    fi

    local random_panel_path random_sub_path
    local panel_port panel_path sub_port sub_path

    random_panel_path="$(random_path_256)"
    while true; do
        random_sub_path="$(random_path_256)"
        [[ "$random_sub_path" != "$random_panel_path" ]] && break
    done

    panel_port="$(read_port "请输入面板端口：")"

    read -r -p "面板路径（留空使用 256 位随机哈希路径 $random_panel_path）：" panel_path
    panel_path="$(normalize_path "${panel_path:-$random_panel_path}")"

    while true; do
        sub_port="$(read_port "请输入订阅端口：")"
        if [[ "$sub_port" == "$panel_port" ]]; then
            warn "订阅端口不能与面板端口相同。"
            continue
        fi
        break
    done

    read -r -p "订阅路径（留空使用 256 位随机哈希路径 $random_sub_path）：" sub_path
    sub_path="$(normalize_path "${sub_path:-$random_sub_path}")"

    "$INSTALL_DIR/sui" setting \
        -port "$panel_port" \
        -path "$panel_path" \
        -subPort "$sub_port" \
        -subPath "$sub_path"

    local username password
    read -r -p "管理员用户名 [admin]：" username
    username="${username:-admin}"

    password="$(random_hash_256)"

    "$INSTALL_DIR/sui" admin -username "$username" -password "$password"

    echo
    info "请保存下面的 S-UI 配置信息："
    echo "  面板端口：$panel_port"
    echo "  面板路径：$panel_path"
    echo "  订阅端口：$sub_port"
    echo "  订阅路径：$sub_path"
    echo "  管理员用户名：$username"
    echo -e "  自动生成密码：${yellow}$password${plain}"
    warn "该密码由 256 位随机数据生成，只显示一次，请立即保存。"
}

start_service() {
    info "加载并启动 systemd 服务..."
    systemctl daemon-reload
    systemctl enable s-ui --now

    if ! systemctl is-active --quiet s-ui; then
        systemctl status s-ui --no-pager -l || true
        fatal "s-ui 服务启动失败，请根据上面的日志检查。"
    fi

    info "s-ui 已安装并启动。"
    "$INSTALL_DIR/sui" uri || true

    echo
    echo "常用命令："
    echo "  s-ui"
    echo "  systemctl status s-ui -l"
    echo "  journalctl -u s-ui.service -e --no-pager"
}

main() {
    require_root
    check_system
    install_dependencies
    download_archive
    verify_archive
    extract_archive
    install_files
    configure_s_ui
    start_service
}

main "$@"
