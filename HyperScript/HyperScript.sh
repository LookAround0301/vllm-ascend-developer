#!/bin/bash

# HyperScript 一键安装脚本
# 交互式 TUI 菜单（上下键 + 空格多选 + 回车确认）
# 支持功能：安装 vllm / vllm-ascend、创建容器、NPU 查询、万能杀、安装 Claude Code 等

# set -euo pipefail

# ==================== 颜色定义 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ==================== 代理配置 ====================
DEFAULT_PROXY_IP="141.3.169.14"
DEFAULT_PROXY_PORT="8080"

# ==================== Docker 容器配置 ====================
DEFAULT_CONTAINER_NAME="super_test"
DEFAULT_IMAGE_ID="8eec2957a42c"

# ==================== vLLM / vLLM-Ascend 配置 ====================
DEFAULT_VLLM_REPO="https://github.com/vllm-project/vllm"
DEFAULT_VLLM_ASCEND_REPO="https://github.com/vllm-project/vllm-ascend.git"
DEFAULT_VLLM_BRANCH="v0.21.0"
DEFAULT_VLLM_ASCEND_BRANCH="main"
DEFAULT_VLLM_INSTALL_DIR="$(pwd)"
DEFAULT_VLLM_ASCEND_INSTALL_DIR="$(pwd)"

# ==================== 运行时状态 ====================

# 脚本所在目录(定位同级附带文件, 如 statusline.py)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==================== Claude Code 配置 ====================
# Node.js 安装包的平台由当前系统的 uname 自动检测。
DEFAULT_NODE_VERSION="v24.14.0"
DEFAULT_NODE_MIRROR_BASE="https://mirrors.huaweicloud.com/nodejs"
# 备选 npm 镜像源（按需取消注释）：
# npm config set registry https://mirrors.tools.huawei.com/npm/
# npm config set registry http://mirrors.cloud.tencent.com/npm/
# npm config set registry https://registry.npmmirror.com
# npm config set registry https://mirrors.huaweicloud.com/repository/npm/
DEFAULT_NPM_REGISTRY="https://registry.npmmirror.com"
DEFAULT_CLAUDE_CODE_INSTALL_DIR="$(pwd)"

# ==================== Codex CLI 配置 ====================
DEFAULT_CODEX_INSTALL_DIR="$(pwd)"
CODEX_PACKAGE="@openai/codex"
DEFAULT_CODEX_BASE_URL="https://api.openai.com/v1"

# ==================== 通用工具函数 ====================

# 输出绿色 [INFO] 日志
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

# 输出黄色 [WARN] 日志（整行黄色）
log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

# 输出红色 [ERROR] 日志
log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 输出成功日志（整行绿色）
log_success() {
    echo -e "${GREEN}[INFO] ✅ $1${NC}"
}

# 输出失败日志（整行红色）
log_fail() {
    echo -e "${RED}[FAIL] ❌ $1${NC}"
}

# 检查命令是否存在，不存在则退出
check_command() {
    if ! command -v $1 &> /dev/null; then
        log_error "命令 $1 不存在，请检查环境"
        exit 1
    fi
}

# 检查文件是否存在，不存在则退出
check_file() {
    if [ ! -f "$1" ]; then
        log_error "文件 $1 不存在"
        exit 1
    fi
}

# 检查目录是否存在，不存在则退出
check_dir() {
    if [ ! -d "$1" ]; then
        log_error "目录 $1 不存在"
        exit 1
    fi
}

# 确保目录存在，不存在则自动创建
ensure_dir() {
    local target_dir="$1"
    if [ ! -d "${target_dir}" ]; then
        echo "目录 ${target_dir} 不存在，正在创建..."
        mkdir -p "${target_dir}"
        if [ $? -ne 0 ]; then
            log_error "创建目录 ${target_dir} 失败"
            exit 1
        fi
    fi
}

# 输出当前系统对应的 Node.js 发布包平台标识，例如 linux-x64 或 darwin-arm64。
# 可选参数用于测试：detect_node_platform [系统名] [机器架构]。
detect_node_platform() {
    local system_name="${1:-$(uname -s)}"
    local machine_arch="${2:-$(uname -m)}"
    local node_os node_arch

    case "${system_name}" in
        Linux)
            node_os="linux"
            ;;
        Darwin)
            node_os="darwin"
            ;;
        *)
            >&2 log_error "不支持的操作系统：${system_name}。Node.js 自动安装仅支持 Linux 和 macOS。"
            return 1
            ;;
    esac

    case "${machine_arch}" in
        x86_64|amd64)
            node_arch="x64"
            ;;
        aarch64|arm64)
            node_arch="arm64"
            ;;
        armv7l)
            if [ "${node_os}" != "linux" ]; then
                >&2 log_error "Node.js 没有 ${node_os}-armv7l 发布包。"
                return 1
            fi
            node_arch="armv7l"
            ;;
        *)
            >&2 log_error "不支持的 CPU 架构：${machine_arch}。"
            return 1
            ;;
    esac

    printf '%s-%s\n' "${node_os}" "${node_arch}"
}

# 确认是否继续（y/n，默认y），输入 n 则 return 0 中断调用方
confirm_to_continue() {
    local confirm
    while true; do
        read -e -p "确认开始安装？(y/n，默认y)：" confirm
        confirm=$(echo "${confirm}" | xargs || echo "y")
        confirm=${confirm:-y}
        confirm=$(echo "${confirm}" | tr 'A-Z' 'a-z')
        if [[ "${confirm}" =~ ^[YyNn]$ ]]; then
            break
        else
            log_error "输入无效！请输入 y 或 n"
        fi
    done
    if [ "${confirm}" != "y" ]; then
        log_info "已取消安装"
        return 1
    fi
    return 0
}

# 交互式选择并切换到有效的远程分支
select_valid_branch() {
    local repo_dir="$1"
    local repo_name="$2"

    if [ -z "${repo_dir}" ] || [ ! -d "${repo_dir}" ]; then
        >&2 echo "[ERROR] 仓库目录不存在或为空：${repo_dir}"
        exit 1
    fi
    if [ -z "${repo_name}" ]; then
        >&2 echo "[ERROR] 仓库名称不能为空"
        exit 1
    fi

    cd "${repo_dir}" || {
        >&2 echo "[ERROR] 无法进入仓库目录 ${repo_dir}"
        exit 1
    }

    >&2 echo "正在拉取 ${repo_name} 所有远程分支信息..."
    if ! git fetch origin --all >/dev/null 2>&1; then
        >&2 echo "[WARNING] 拉取远程分支信息失败，将使用本地已有分支列表"
    fi

    local all_branches
    all_branches=$(git branch -a | \
                   grep -E '^[[:space:]]*remotes/origin/' | \
                   grep -v -E 'HEAD|->' | \
                   sed -e 's/^[[:space:]]*remotes\/origin\///g' -e 's/[[:space:]]*$//g' | \
                   sort -u)

    if [ -z "${all_branches}" ]; then
        >&2 echo "[ERROR] 未找到 ${repo_name} 的有效分支"
        exit 1
    fi

    >&2 echo -e "\n===== ${repo_name} 所有可用分支 ====="
    echo "${all_branches}" | while read -r branch; do
        >&2 echo "  - ${branch}"
    done
    >&2 echo "======================================="

    local selected_branch
    while true; do
        read -e -p "请输入要 checkout 的 ${repo_name} 分支名（直接回车使用默认分支 main）：" selected_branch
        selected_branch=$(echo "${selected_branch}" | xargs)

        if [ -z "${selected_branch}" ]; then
            selected_branch="main"
            >&2 echo "未输入分支名，将使用默认分支：${selected_branch}"
        fi

        if echo "${all_branches}" | grep -i "^${selected_branch}$" >/dev/null; then
            selected_branch=$(echo "${all_branches}" | grep -i "^${selected_branch}$" | head -n1)
            >&2 echo "选择的分支有效：${selected_branch}"
            break
        else
            >&2 echo "[ERROR] 分支 ${selected_branch} 不存在，请重新输入！"
            >&2 echo "当前可用分支列表："
            echo "${all_branches}" | while read -r branch; do
                >&2 echo "  - ${branch}"
            done
        fi
    done

    >&2 echo "正在切换到 ${repo_name} 的 ${selected_branch} 分支..."
    if ! git fetch origin "${selected_branch}" >/dev/null 2>&1; then
        >&2 echo "[WARNING] 拉取 ${selected_branch} 分支最新代码失败，将使用本地代码"
    fi

    if git checkout "${selected_branch}" >/dev/null 2>&1; then
        >&2 echo "成功切换到已存在的分支：${selected_branch}"
    else
        if git checkout -b "${selected_branch}" --track "origin/${selected_branch}" >/dev/null 2>&1; then
            >&2 echo "成功创建并切换到分支：${selected_branch}"
        else
            >&2 echo "[ERROR] checkout ${repo_name} 的 ${selected_branch} 分支失败"
            exit 1
        fi
    fi

    cd - >/dev/null 2>&1 || exit 1
}

# 获取安装目录（CLI参数 > 环境变量 > 交互输入 > 默认值）
get_install_dir() {
    local cli_dir="$1"
    local default_dir="$(pwd)"
    local install_dir=""
    local user_input_dir=""

    if [ -n "${cli_dir}" ]; then
        install_dir=$(echo "${cli_dir}" | sed -e 's/[^a-zA-Z0-9\/_-]//g' -e 's/^\s*//g' -e 's/\s*$//g')
        >&2 log_info "使用命令行指定的安装目录：${install_dir}"
    elif [ -n "${VLLM_INSTALL_DIR:-}" ]; then
        install_dir=$(echo "${VLLM_INSTALL_DIR}" | sed -e 's/[^a-zA-Z0-9\/_-]//g' -e 's/^\s*//g' -e 's/\s*$//g')
        >&2 log_info "使用环境变量 VLLM_INSTALL_DIR 指定的目录：${install_dir}"
    else
        >&2 read -e -p "请输入安装目录（默认：${default_dir}）：" user_input_dir
        user_input_dir=$(echo "${user_input_dir}" | sed -e 's/[^a-zA-Z0-9\/_-]//g' -e 's/^\s*//g' -e 's/\s*$//g')
        install_dir="${user_input_dir:-${default_dir}}"
        >&2 log_info "确认安装目录：${install_dir}"
    fi

    if [[ ! "${install_dir}" =~ ^/ ]]; then
        >&2 log_warn "警告：输入的不是绝对路径，自动转换为绝对路径..."
        install_dir=$(realpath -m "${install_dir}")
        >&2 log_info "转换后的绝对路径：${install_dir}"
    fi

    mkdir -p "$(dirname "${install_dir}")" || {
        >&2 log_error "无法创建安装目录的父路径 $(dirname "${install_dir}")"
        exit 1
    }

    install_dir=$(echo "${install_dir}" | sed 's:/*$::')   # 去除末尾斜杠
    echo "${install_dir}"
}

# ==================== 安装函数 ====================

# 安装 vllm（源码安装，参数：安装目录、仓库地址、分支）
install_vllm() {
    local install_dir="${1:-$DEFAULT_VLLM_INSTALL_DIR}"
    local ascend_repo="${2:-$DEFAULT_VLLM_REPO}"
    local branch="${3:-$DEFAULT_VLLM_BRANCH}"
    local skip_confirm="${4:-}"
    local pkg_name="vllm"
    local repo_name="vllm"

    install_dir=$(echo "${install_dir}" | sed -e 's/[^a-zA-Z0-9\/_-]//g' -e 's/^\s*//g' -e 's/\s*$//g' -e 's:/*$::')
    [[ ! "${install_dir}" =~ ^/ ]] && install_dir=$(realpath -m "${install_dir}")

    # 清理旧版本
    if pip show "${pkg_name}" >/dev/null 2>&1; then
        if pip uninstall -y -q "${pkg_name}" >/dev/null 2>&1; then
            log_success "已卸载旧版本 ${pkg_name}"
        else
            log_warn "卸载 ${pkg_name} 失败，尝试强制清理..."
            pip uninstall -y "${pkg_name}" || {
                log_fail "旧版本 ${pkg_name} 卸载失败，请手动执行：pip uninstall -y ${pkg_name}"
                return 1
            }
        fi
    fi

    # 单独调用时显示详情并确认
    if [[ -z "$skip_confirm" ]]; then
        echo -e "${GREEN}── 安装 ${repo_name} ──${NC}"
        log_info "目录：${install_dir} | 仓库：${ascend_repo} | 分支：${branch}"
        confirm_to_continue || return 0
    fi

    ensure_dir "${install_dir}"

    # 克隆/更新仓库
    local repo_dir="${install_dir}/${repo_name}"
    if [ -d "${repo_dir}" ]; then
        log_info "${repo_name} 仓库已存在，更新中..."
    else
        log_info "正在克隆 ${repo_name} 仓库..."
        if ! git clone "${ascend_repo}" "${repo_dir}"; then
            log_error "克隆 ${repo_name} 仓库失败"
            return 1
        fi
    fi

    cd "${repo_dir}" || { log_error "无法进入仓库目录 ${repo_dir}"; return 1; }

    # 切换分支
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ "${current_branch}" != "${branch}" ]; then
        log_info "切换分支 ${current_branch} → ${branch}"
        git fetch origin "${branch}" >/dev/null 2>&1 || true
        if git checkout "${branch}" >/dev/null 2>&1; then
            :
        elif git checkout -b "${branch}" --track "origin/${branch}" >/dev/null 2>&1; then
            :
        else
            log_warn "分支 ${branch} 不存在，请从已有分支中选择"
            if ! select_valid_branch "${repo_dir}" "${repo_name}"; then
                log_error "选择分支失败"
                return 1
            fi
        fi
    fi

    # 安装
    log_info "正在安装 ${repo_name} 包（可能耗时较长）..."
    if VLLM_TARGET_DEVICE=empty pip install -v -e . --no-build-isolation -i https://pypi.tuna.tsinghua.edu.cn/simple; then
        log_success "${repo_name} 包安装成功！"
    else
        log_fail "${repo_name} 包安装失败，请检查上述错误日志"
        return 1
    fi
}

# 安装 vllm-ascend（源码安装，参数：安装目录、仓库地址、分支）
install_vllm_ascend() {
    local install_dir="${1:-$DEFAULT_VLLM_ASCEND_INSTALL_DIR}"
    local ascend_repo="${2:-$DEFAULT_VLLM_ASCEND_REPO}"
    local branch="${3:-$DEFAULT_VLLM_ASCEND_BRANCH}"
    local skip_confirm="${4:-}"
    local pkg_name="vllm_ascend"
    local repo_name="vllm-ascend"

    install_dir=$(echo "${install_dir}" | sed -e 's/[^a-zA-Z0-9\/_-]//g' -e 's/^\s*//g' -e 's/\s*$//g' -e 's:/*$::')
    [[ ! "${install_dir}" =~ ^/ ]] && install_dir=$(realpath -m "${install_dir}")

    # 清理旧版本
    if pip show "${pkg_name}" >/dev/null 2>&1; then
        if pip uninstall -y -q "${pkg_name}" >/dev/null 2>&1; then
            log_success "已卸载旧版本 ${pkg_name}"
        else
            log_warn "卸载 ${pkg_name} 失败，尝试强制清理..."
            pip uninstall -y "${pkg_name}" || {
                log_fail "旧版本 ${pkg_name} 卸载失败，请手动执行：pip uninstall -y ${pkg_name}"
                return 1
            }
        fi
    fi

    # 单独调用时显示详情并确认
    if [[ -z "$skip_confirm" ]]; then
        echo -e "${GREEN}── 安装 ${repo_name} ──${NC}"
        log_info "目录：${install_dir} | 仓库：${ascend_repo} | 分支：${branch}"
        confirm_to_continue || return 0
    fi

    ensure_dir "${install_dir}"

    # 克隆/更新仓库
    local repo_dir="${install_dir}/${repo_name}"
    if [ -d "${repo_dir}" ]; then
        log_info "${repo_name} 仓库已存在，更新中..."
    else
        log_info "正在克隆 ${repo_name} 仓库..."
        if ! git clone "${ascend_repo}" "${repo_dir}"; then
            log_error "克隆 ${repo_name} 仓库失败"
            return 1
        fi
    fi

    cd "${repo_dir}" || { log_error "无法进入仓库目录 ${repo_dir}"; return 1; }

    # 切换分支
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ "${current_branch}" != "${branch}" ]; then
        log_info "切换分支 ${current_branch} → ${branch}"
        git fetch origin "${branch}" >/dev/null 2>&1 || true
        if git checkout "${branch}" >/dev/null 2>&1; then
            :
        elif git checkout -b "${branch}" --track "origin/${branch}" >/dev/null 2>&1; then
            :
        else
            log_warn "分支 ${branch} 不存在，请从已有分支中选择"
            if ! select_valid_branch "${repo_dir}" "${repo_name}"; then
                log_error "选择分支失败"
                return 1
            fi
        fi
    fi

    # 安装
    log_info "正在安装 ${repo_name} 包（可能耗时较长）..."
    if pip install -v -e . -i https://pypi.tuna.tsinghua.edu.cn/simple; then
        log_success "${repo_name} 包安装成功！"
    else
        log_fail "${repo_name} 包安装失败，请检查上述错误日志"
        return 1
    fi
}

# 一键安装 vllm + vllm-ascend（参数：安装目录）
install_vllm_all() {
    local install_dir="${1:-$DEFAULT_VLLM_INSTALL_DIR}"

    echo -e "${GREEN}━━━ 一键安装 vllm + vllm-ascend ━━━${NC}"
    log_info "目录：${install_dir} | vllm: ${DEFAULT_VLLM_BRANCH} | vllm-ascend: ${DEFAULT_VLLM_ASCEND_BRANCH}"
    echo

    echo -e "${GREEN}── [1/2] 安装 vllm ──${NC}"
    install_vllm "${install_dir}" "$DEFAULT_VLLM_REPO" "$DEFAULT_VLLM_BRANCH" "skip_confirm" || {
        log_fail "vllm 安装失败，终止一键安装"
        return 1
    }
    echo

    echo -e "${GREEN}── [2/2] 安装 vllm-ascend ──${NC}"
    install_vllm_ascend "${install_dir}" "$DEFAULT_VLLM_ASCEND_REPO" "$DEFAULT_VLLM_ASCEND_BRANCH" "skip_confirm" || {
        log_fail "vllm-ascend 安装失败，终止一键安装"
        return 1
    }
    echo

    log_success "vllm + vllm-ascend 一键安装完成！"
}


# ==================== 代理管理函数 ====================

# 清除所有代理配置（临时环境变量 + ~/.bashrc + pip + git）
clear_proxy() {
    unset http_proxy https_proxy no_proxy GIT_SSL_NO_VERIFY 2>/dev/null || true

    local BASHRC_FILE="$HOME/.bashrc"
    sed -i '/# 自动配置的代理（由安装脚本添加）/,+5d' "$BASHRC_FILE" 2>/dev/null || true
    sed -i '/# 自动配置的代理（由安装脚本添加）/,+5d' "/etc/profile.d/proxy.sh" 2>/dev/null || true
    rm -f "$HOME/.pip/pip.conf" 2>/dev/null || true
    rm -f "/root/.gitconfig" 2>/dev/null || true

    log_info "✅ 代理配置已清除（环境变量、~/.bashrc、/etc/profile.d、pip、git）"
    log_info "💡 若要立即让清理生效，执行: source ~/.bashrc"
}

# 静默设置代理（参数：可选IP、PORT），只设置环境变量 + .bashrc + pip.conf，不打印不测试
setup_proxy_silent() {
    local input_ip="${1:-$DEFAULT_PROXY_IP}"
    local input_port="${2:-$DEFAULT_PROXY_PORT}"

    input_ip=$(echo "${input_ip}" | xargs 2>/dev/null || true)
    input_ip="${input_ip:-$DEFAULT_PROXY_IP}"
    input_port=$(echo "${input_port}" | xargs 2>/dev/null || true)
    input_port="${input_port:-$DEFAULT_PROXY_PORT}"

    # 清理旧配置
    unset http_proxy https_proxy no_proxy GIT_SSL_NO_VERIFY 2>/dev/null || true
    local BASHRC_FILE="$HOME/.bashrc"
    sed -i '/# 自动配置的代理（由安装脚本添加）/,+5d' "$BASHRC_FILE" 2>/dev/null || true
    rm -f "$HOME/.pip/pip.conf" 2>/dev/null || true

    # 设置临时环境变量
    export http_proxy="http://p_atlas:proxy%40123@${input_ip}:${input_port}"
    export https_proxy="http://p_atlas:proxy%40123@${input_ip}:${input_port}"
    export no_proxy=127.0.0.1,.huawei.com,localhost,local,.local
    export GIT_SSL_NO_VERIFY=1

    # 写入 .bashrc
    sed -i '/http_proxy=/d' "$BASHRC_FILE"
    sed -i '/https_proxy=/d' "$BASHRC_FILE"
    sed -i '/no_proxy=/d' "$BASHRC_FILE"
    sed -i '/GIT_SSL_NO_VERIFY=/d' "$BASHRC_FILE"

    echo -e "\n# 自动配置的代理（由安装脚本添加）" >> "$BASHRC_FILE"
    echo "export http_proxy=\"http://p_atlas:proxy%40123@${input_ip}:${input_port}\"" >> "$BASHRC_FILE"
    echo "export https_proxy=\"http://p_atlas:proxy%40123@${input_ip}:${input_port}\"" >> "$BASHRC_FILE"
    echo "export no_proxy=\"127.0.0.1,.huawei.com,localhost,local,.local\"" >> "$BASHRC_FILE"
    echo "export GIT_SSL_NO_VERIFY=1" >> "$BASHRC_FILE"

    # 同步代理到 /etc/profile.d/proxy.sh：登录 shell（bash -l，如 VS Code Server、ssh 登录执行）
    # 只读 /etc/profile 不读 ~/.bashrc，不同步则这些环境下缺代理变量。幂等：先删旧块再追加。
    local PROFILED_FILE="/etc/profile.d/proxy.sh"
    if touch "${PROFILED_FILE}" 2>/dev/null; then
        sed -i '/# 自动配置的代理（由安装脚本添加）/,+5d' "${PROFILED_FILE}" 2>/dev/null || true
        echo -e "\n# 自动配置的代理（由安装脚本添加）" >> "${PROFILED_FILE}"
        echo "export http_proxy=\"http://p_atlas:proxy%40123@${input_ip}:${input_port}\"" >> "${PROFILED_FILE}"
        echo "export https_proxy=\"http://p_atlas:proxy%40123@${input_ip}:${input_port}\"" >> "${PROFILED_FILE}"
        echo "export no_proxy=\"127.0.0.1,.huawei.com,localhost,local,.local\"" >> "${PROFILED_FILE}"
        echo "export GIT_SSL_NO_VERIFY=1" >> "${PROFILED_FILE}"
        chmod 644 "${PROFILED_FILE}" 2>/dev/null || true
    else
        log_warn "无 /etc/profile.d 写权限，代理仅写入 ~/.bashrc（登录 shell 环境可能缺代理）"
    fi

    # 写入 pip 配置
    mkdir -p "$HOME/.pip"
    cat > "$HOME/.pip/pip.conf" << EOF
[global]
proxy = $http_proxy
trusted-host = pypi.org
               files.pythonhosted.org
               pypi.python.org
EOF
}

# 确保网络连通：直连 → 默认代理 → 交互配置
ensure_network() {
    # 1. 直连测试
    log_info "正在检查网络连通性..."
    if curl -s --connect-timeout 1 http://www.baidu.com > /dev/null 2>&1; then
        log_info "✅ 网络连接正常（直连）"
        return 0
    fi

    # 2. 尝试用默认代理
    log_info "直连不通，尝试代理 $DEFAULT_PROXY_IP:$DEFAULT_PROXY_PORT ..."
    if [ -z "$http_proxy" ]; then
        setup_proxy_silent
    fi
    if curl -s --connect-timeout 1 --proxy "$http_proxy" http://www.baidu.com > /dev/null 2>&1; then
        log_info "✅ 代理已自动配置并连通 ($DEFAULT_PROXY_IP:$DEFAULT_PROXY_PORT)"
        return 0
    fi

    # 3. 默认代理不通，TUI 选择
    local net_cursor=0
    local net_n=3
    local net_key net_i net_desc
    tput civis 2>/dev/null

    while true; do
        clear
        echo "=================================="
        echo -e "  ${RED}⚠️ 默认代理 ($DEFAULT_PROXY_IP:$DEFAULT_PROXY_PORT) 连接失败${NC}"
        echo "=================================="
        for ((net_i=0; net_i<net_n; net_i++)); do
            case $net_i in
                0) net_desc="输入新的代理 IP 和 PORT" ;;
                1) net_desc="修改脚本默认配置后重启" ;;
                2) net_desc="取消当前操作" ;;
            esac
            if [ $net_i -eq $net_cursor ]; then
                echo -e "\e[7m  $((net_i+1)). ${net_desc}\e[0m"
            else
                echo -e "  $((net_i+1)). ${net_desc}"
            fi
        done
        echo "=================================="
        echo -e "  ${YELLOW}↑↓ 移动 | Enter 确认${NC}"
        echo -e "  ${YELLOW}提示: 选项1仅当前终端生效，永久生效需修改脚本默认配置${NC}"

        IFS= read -rsn1 net_key
        if [[ "$net_key" == $'\x1b' ]]; then
            IFS= read -rsn2 -t 0.1 net_key
            if [[ "$net_key" == "[A" ]]; then
                ((net_cursor--)); [ $net_cursor -lt 0 ] && net_cursor=$((net_n-1))
            elif [[ "$net_key" == "[B" ]]; then
                ((net_cursor++)); [ $net_cursor -ge $net_n ] && net_cursor=0
            fi
            continue
        fi
        [[ "$net_key" == "" ]] && break
    done

    tput cnorm 2>/dev/null

    case $((net_cursor + 1)) in
        1)
            local user_ip user_port
            read -e -p "代理IP: " user_ip
            read -e -p "代理PORT: " user_port
            # 覆写默认代理变量，后续菜单配置显示和 setup_proxy_silent 都用新值
            DEFAULT_PROXY_IP="${user_ip:-$DEFAULT_PROXY_IP}"
            DEFAULT_PROXY_PORT="${user_port:-$DEFAULT_PROXY_PORT}"
            setup_proxy_silent "$DEFAULT_PROXY_IP" "$DEFAULT_PROXY_PORT"
            if curl -s --connect-timeout 10 --proxy "$http_proxy" http://www.baidu.com > /dev/null 2>&1; then
                log_info "✅ 代理配置成功"
                return 0
            else
                log_error "代理仍然不通，请手动确认连通性后修改脚本顶部的 DEFAULT_PROXY_IP 和 DEFAULT_PROXY_PORT 并重新运行脚本"
                return 1
            fi
            ;;
        2)
            log_info "请修改脚本顶部的 DEFAULT_PROXY_IP 和 DEFAULT_PROXY_PORT 后重新运行"
            return 1
            ;;
        3)
            log_info "已取消"
            return 1
            ;;
    esac
}

# ==================== Docker / 进程管理函数 ====================

# 创建挂载 Ascend NPU 设备的 vllm Docker 容器
create_vllm_container() {
    echo -e "${GREEN}── 创建 vllm 容器 ──${NC}"
    check_command docker

    echo -e "\n${YELLOW}[INFO] 本地可用镜像列表（ID: 仓库:标签）：${NC}"
    local local_images
    local_images=$(docker images --format "{{.ID}}: {{.Repository}}:{{.Tag}}" | grep -v "<none>:<none>" || true)
    if [ -n "$local_images" ]; then
        echo "$local_images" | while read -r img; do
            echo "  - $img"
        done
    else
        log_warn "本地未检测到有效镜像，将使用默认镜像ID"
    fi

    local selected_image
    while true; do
        read -e -p "请输入要使用的镜像ID [默认: $DEFAULT_IMAGE_ID]: " selected_image
        selected_image=$(echo "${selected_image}" | xargs || true)
        selected_image=${selected_image:-$DEFAULT_IMAGE_ID}

        if docker images -q "$selected_image" >/dev/null 2>&1; then
            log_info "选择的镜像ID有效：$selected_image"
            break
        else
            log_error "镜像ID $selected_image 本地不存在，请重新输入！"
            if [ -n "$local_images" ]; then
                echo -e "${YELLOW}本地可用镜像ID参考：${NC}"
                docker images --format "{{.ID}}" | grep -v "<none>" | while read -r img_id; do
                    echo "  - $img_id"
                done
            fi
        fi
    done

    local selected_container
    while true; do
        read -e -p "请输入要创建的容器名 [默认: $DEFAULT_CONTAINER_NAME]: " selected_container
        selected_container=$(echo "${selected_container}" | xargs || true)
        selected_container=${selected_container:-$DEFAULT_CONTAINER_NAME}

        local exist_container
        exist_container=$(docker ps -a --filter "name=^/${selected_container}$" -q)
        if [ -n "$exist_container" ]; then
            log_error "容器名 $selected_container 已存在（运行/停止状态），请更换名称！"
            echo -e "${YELLOW}当前本地已存在的容器名列表：${NC}"
            docker ps -a --format "{{.Names}}" | sort | while read -r name; do
                echo "  - $name"
            done
        else
            log_info "选择的容器名有效：$selected_container"
            break
        fi
    done

    echo -e "\n${GREEN}开始执行容器创建命令，耗时约数秒...${NC}"
    docker run --name "${selected_container}" -it -d --net=host --shm-size=500g \
           --privileged=true \
           -w /home \
           --device=/dev/davinci_manager \
           --device=/dev/hisi_hdc \
           --device=/dev/devmm_svm \
           --entrypoint=bash \
           -v /usr/local/Ascend/driver:/usr/local/Ascend/driver \
           -v /usr/local/dcmi:/usr/local/dcmi \
           -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
           -v /usr/local/sbin:/usr/local/sbin \
           -v /home:/home \
           -v /tmp:/tmp \
           -v /data:/data \
           -v /mnt/:/mnt/ \
           -v /usr/share/zoneinfo/Asia/Shanghai:/etc/localtime \
           -v /etc/hccn.conf:/etc/hccn.conf \
           -e http_proxy="${http_proxy:-}" \
           -e https_proxy="${https_proxy:-}" \
           "${selected_image}"

    if docker ps -a --filter "name=^/${selected_container}$" -q >/dev/null 2>&1; then
        log_info "✅ 容器 ${selected_container} 创建成功！"
        log_info "容器状态查询：docker ps -a | grep ${selected_container}"
        log_info "进入容器命令：docker exec -it ${selected_container} bash"

        local enter_container_flag
        while true; do
            read -e -p "是否立即进入该容器？(y/n，默认n)：" enter_container_flag
            enter_container_flag=$(echo "${enter_container_flag}" | xargs || echo "n")

            if [[ "${enter_container_flag}" =~ ^[YyNn]$ ]] || [ -z "${enter_container_flag}" ]; then
                enter_container_flag=${enter_container_flag:-n}
                enter_container_flag=$(echo "${enter_container_flag}" | tr 'A-Z' 'a-z')
                break
            else
                log_error "输入无效！请输入 y 或 n（直接回车默认 n）"
            fi
        done

        if [ "${enter_container_flag}" = "y" ]; then
            log_info "正在进入容器 ${selected_container} ..."
            log_info "进入容器后需要重新执行本脚本以进行后续安装操作 ..."
            docker exec -it "${selected_container}" bash
            echo -e "${GREEN}✅ 已成功退出容器 ${selected_container}，回到宿主机环境！${NC}"
        else
            log_info "已选择不立即进入容器，可后续执行上述命令手动进入"
        fi

    else
        log_error "❌ 容器 ${selected_container} 创建失败，请检查docker命令输出！"
        return 1
    fi
    echo "=================================="
}

# 强制查杀所有 python/torchrun/ray/vllm 相关进程
kill_all_related_process() {
    echo -e "${RED}── 万能杀 ──${NC}"
    log_info "1. 查杀python相关进程"
    ps -ef | grep "python"| grep -v grep | awk '{print $2}' | xargs -t -i kill -9 {} 2>/dev/null || true
    pkill -9 python 2>/dev/null || true

    log_info "2. 查杀torchrun相关进程"
    pkill -9 torchrun 2>/dev/null || true

    log_info "3. 停止ray服务"
    ray stop 2>/dev/null || true

    log_info "4. 查杀python/defunct僵尸进程（父进程）"
    ps -ef | grep "defunct"|grep python| awk '{print $3}'|xargs -t -i kill -9 {} 2>/dev/null || true

    log_info "5. 查杀torchrun/defunct僵尸进程（父进程）"
    ps -ef | grep "defunct"|grep torchrun| awk '{print $3}'|xargs -t -i kill -9 {} 2>/dev/null || true

    log_info "6. 查杀VLLM进程"
    pkill -9 VLLM* 2>/dev/null || true

    echo -e "\n✅ ${GREEN}万能杀执行完成！所有相关进程已强制查杀${NC}"
    echo "=================================="
}

# 一键停止所有运行中的 Docker 容器
stop_all_containers() {
    echo -e "${YELLOW}── 停止所有运行中容器 ──${NC}"
    check_command docker

    local running_containers
    running_containers=$(timeout 5 docker ps -q 2>/dev/null)

    if [ -z "$running_containers" ]; then
        log_info "✅ 本地无运行中的Docker容器/或Docker操作超时，无需停止"
        return 0
    fi

    local stop_container_list
    stop_container_list=$(timeout 5 docker ps --format "{{.ID}}::{{.Names}}" 2>/dev/null)
    if [ -z "$stop_container_list" ]; then
        stop_container_list=$(echo "$running_containers" | awk '{print $0 "::未知名称"}')
        log_warn "⚠️  容器名称查询超时，将按容器ID处理"
    fi

    log_info "检测到以下运行中的容器，即将停止："
    timeout 5 docker ps --format "  - 容器名: {{.Names}} | 容器ID: {{.ID}} | 镜像: {{.Image}}" 2>/dev/null || log_warn "⚠️  容器信息查询超时，将直接批量处理容器ID"
    echo

    local confirm_flag
    while true; do
        read -e -p "确认是否停止以上所有运行中容器？(y/n，默认n)：" confirm_flag
        confirm_flag=$(echo "${confirm_flag}" | xargs || echo "n")
        confirm_flag=${confirm_flag:-n}
        confirm_flag=$(echo "${confirm_flag}" | tr 'A-Z' 'a-z')

        if [[ "${confirm_flag}" =~ ^[YyNn]$ ]]; then
            break
        else
            log_error "输入无效！请输入 y 或 n（直接回车默认 n）"
        fi
    done

    if [ "${confirm_flag}" = "y" ]; then
        log_info "开始停止所有运行中容器（5秒全局超时，超时直接跳过）..."
        timeout 5 docker stop -t 5 $(docker ps -q) 2>/dev/null
        timeout 5 docker kill $(docker ps -q) 2>/dev/null || true

        local remaining_containers
        remaining_containers=$(timeout 5 docker ps -q 2>/dev/null)

        local not_stopped_containers=""
        if [ -n "$remaining_containers" ] && [ -n "$stop_container_list" ]; then
            while IFS="::" read -r cid cname; do
                if echo "$remaining_containers" | grep -qw "$cid"; then
                    not_stopped_containers+="  - 容器名: $cname | 容器ID: $cid\n"
                fi
            done <<< "$stop_container_list"
        fi

        if [ -z "$remaining_containers" ]; then
            log_info "✅ 所有运行中容器已成功停止！"
            timeout 5 docker ps -a --format "  - {{.Names}} [{{.Status}}]" 2>/dev/null || true
        else
            log_error "❌ 存在容器超时未停止（已跳过卡顿操作），请手动处理！"
            if [ -n "$not_stopped_containers" ]; then
                echo -e "${not_stopped_containers}"
            else
                echo "  - 未停止容器ID列表：$remaining_containers"
            fi
        fi
    else
        log_info "已取消停止容器操作，无任何变更"
    fi
    echo "=================================="
}

# 查询 NPU 卡上正在运行的进程及其工作目录
check_npu_occupancy() {
    echo "=================================="
    echo -e "${YELLOW}查看NPU占用者（进程号+工作目录）${NC}"
    echo "=================================="
    check_command npu-smi info
    check_command pwdx

    log_info "正在执行npu-smi info获取NPU进程原始数据..."
    local npu_smi_raw
    npu_smi_raw=$(npu-smi info 2>/dev/null | grep -v "^$")

    local process_area
    process_area=$(echo "$npu_smi_raw" | awk '
        /Process id/ {flag=1; next}  # 匹配Process id标题，开启进程区解析
        flag { print }              # 进程区内的所有行全部保留并打印
    ' | grep -v "^$")

    echo -e "\n${36}[DEBUG] npu-smi info进程区原始内容：${NC}"
    echo -e "${36}$process_area${NC}"
    echo "----------------------------------"

    local pids
    pids=$(echo "$process_area" | grep -oE '[0-9]{4,}' | sort -u | uniq)

    if [ -z "$pids" ]; then
        log_info "${RED}❌ 未检测到NPU上有运行中的进程！${NC}"
        echo "=================================="
        return 0
    fi

    local pid_count=$(echo "$pids" | wc -w)
    log_info "✅ 成功提取到 $pid_count 个有效NPU进程号，正在查询工作目录（pwdx）..."
    echo -e "\n${GREEN}========== NPU占用进程详情 ==========${NC}"
    echo -e "${GREEN}PID\t| 工作目录/使用者路径${NC}"
    echo "----------------------------------"
    for pid in $pids; do
        local pwdx_result
        pwdx_result=$(pwdx "$pid" 2>/dev/null | awk -F': ' '{print $2}')
        if [ -n "$pwdx_result" ]; then
            echo -e "${YELLOW}$pid${NC}\t| $pwdx_result"
        else
            echo -e "${YELLOW}$pid${NC}\t| ${RED}进程已退出/无权限查看目录${NC}"
        fi
    done
    echo "----------------------------------"
    log_info "✅ NPU占用者查询完成！"
    echo "=================================="
    return 0
}

# ==================== Claude Code 安装函数 ====================

# 安装 Claude Code CLI（Node.js + npm，含多源回退）
# ==================== VS Code 扩展配置函数 ====================

# 配置 VS Code Claude Code 扩展（写入 Machine 作用域设置，幂等合并）。
# 背景：VS Code 面板的 claude 子进程只继承扩展宿主环境（不含 ~/.bashrc 的代理等变量，
# 且宿主会把 http_proxy/https_proxy 以空字符串形式传入、优先级高于 settings.json env）；
# 扩展还会从 claudeCode.environmentVariables 注入网关配置 —— 若用户本地 VS Code User 设置
# 里存有旧网关（如 Kimi），会整体覆盖 ~/.claude/settings.json 的配置导致 401。
# Machine 作用域优先级高于 User 作用域，写这里可一并解决，新容器首次连上 VS Code 即可直接对话。
configure_claude_vscode_extension() {
    local machine_settings_dir="$HOME/.vscode-server/data/Machine"

    mkdir -p "${machine_settings_dir}"

    # 网关/密钥以 ~/.claude/settings.json 的 env 为单一来源；代理取当前 shell（安装流程前面已配好）
    if CLAUDE_PROXY_HTTP="${http_proxy:-}" CLAUDE_PROXY_HTTPS="${https_proxy:-}" CLAUDE_PROXY_NO="${no_proxy:-}" node <<'NODE'
const fs = require('fs'), path = require('path'), os = require('os');
const claudeEnvFile = path.join(os.homedir(), '.claude', 'settings.json');
const machineFile = path.join(os.homedir(), '.vscode-server', 'data', 'Machine', 'settings.json');

let src = {};
try { src = JSON.parse(fs.readFileSync(claudeEnvFile, 'utf-8')).env || {}; } catch (e) {}

const list = [
    { name: 'ANTHROPIC_BASE_URL', value: src.ANTHROPIC_BASE_URL || 'https://open.bigmodel.cn/api/anthropic' },
    { name: 'ANTHROPIC_API_KEY', value: src.ANTHROPIC_API_KEY || 'YOUR_API_KEY_HERE' },
    { name: 'ANTHROPIC_DEFAULT_HAIKU_MODEL', value: src.ANTHROPIC_DEFAULT_HAIKU_MODEL || 'glm-5.3[1m]' },
    { name: 'ANTHROPIC_DEFAULT_SONNET_MODEL', value: src.ANTHROPIC_DEFAULT_SONNET_MODEL || 'glm-5.3[1m]' },
    { name: 'ANTHROPIC_DEFAULT_OPUS_MODEL', value: src.ANTHROPIC_DEFAULT_OPUS_MODEL || 'glm-5.3[1m]' },
];
// 企业网：直连不通，必须走代理；且代理做 TLS 中间人，需关掉证书校验
if (process.env.CLAUDE_PROXY_HTTPS) {
    list.push({ name: 'http_proxy', value: process.env.CLAUDE_PROXY_HTTP || process.env.CLAUDE_PROXY_HTTPS });
    list.push({ name: 'https_proxy', value: process.env.CLAUDE_PROXY_HTTPS });
    list.push({ name: 'no_proxy', value: process.env.CLAUDE_PROXY_NO || '127.0.0.1,.huawei.com,localhost,local,.local' });
}
list.push({ name: 'NODE_TLS_REJECT_UNAUTHORIZED', value: '0' });
list.push({ name: 'GIT_SSL_NO_VERIFY', value: '1' });

let data = {};
try {
    data = fs.existsSync(machineFile) ? JSON.parse(fs.readFileSync(machineFile, 'utf-8')) : {};
} catch (e) {
    try { fs.renameSync(machineFile, machineFile + '.bak-preinstall'); } catch (_) {}  // 旧文件损坏：备份再重建
    data = {};
}
data['claudeCode.disableLoginPrompt'] = true;   // 第三方网关配置，不走 Anthropic OAuth 登录
data['claudeCode.environmentVariables'] = list; // 整体覆盖用户本地（可能过期的）注入配置
fs.writeFileSync(machineFile, JSON.stringify(data, null, 4) + '\n', 'utf-8');
NODE
    then
        log_info "已写入 VS Code Machine 设置: ${machine_settings_dir}/settings.json"
        log_info "注入 claudeCode.environmentVariables（网关/密钥/代理/TLS）+ claudeCode.disableLoginPrompt"
        if [ -z "${https_proxy:-}" ]; then
            log_warn "当前 shell 未设置代理，本次未注入代理 —— 企业网内 VS Code 面板可能无法联网"
        fi
    else
        log_warn "写入 VS Code Machine 设置失败（不影响终端使用；VS Code 面板可能需要手动配置）"
    fi
}

install_claude_code() {
    local install_dir="${1:-$DEFAULT_CLAUDE_CODE_INSTALL_DIR}"

    echo -e "${GREEN}── 安装 Claude Code ──${NC}"

    # 根据当前操作系统和 CPU 架构选择 Node.js 发布包。
    local NODE_VERSION="${DEFAULT_NODE_VERSION}"
    local NODE_PLATFORM
    if ! NODE_PLATFORM="$(detect_node_platform)"; then
        return 1
    fi
    local NODE_FILENAME="node-${NODE_VERSION}-${NODE_PLATFORM}.tar.gz"
    local NODE_DOWNLOAD_URL="${DEFAULT_NODE_MIRROR_BASE}/${NODE_VERSION}/${NODE_FILENAME}"
    local NPM_REGISTRY="${DEFAULT_NPM_REGISTRY}"
    # 获取工作目录
    local work_dir="${install_dir}"
    local node_env_dir="${work_dir}/claude_code_env"
    local node_archive_path="${node_env_dir}/${NODE_FILENAME}"
    local node_extract_dir="${node_env_dir}/node-${NODE_VERSION}-${NODE_PLATFORM}"
    local node_bin_dir="${node_extract_dir}/bin"

    ensure_dir "${node_env_dir}"

    # 打印安装配置
    log_info "目录：${work_dir} | Node：${NODE_VERSION} (${NODE_PLATFORM}) | npm 源：${NPM_REGISTRY}"

    local confirm_install
    while true; do
        read -e -p "确认开始安装？(y/n，默认y)：" confirm_install
        confirm_install=$(echo "${confirm_install}" | xargs || echo "y")
        confirm_install=${confirm_install:-y}
        confirm_install=$(echo "${confirm_install}" | tr 'A-Z' 'a-z')
        if [[ "${confirm_install}" =~ ^[YyNn]$ ]]; then
            break
        else
            log_error "输入无效！请输入 y 或 n"
        fi
    done

    if [ "${confirm_install}" != "y" ]; then
        log_info "已取消安装"
        return 0
    fi

    # ===== Step 1/4: 下载 Node.js =====
    echo -e "\n${GREEN}── [1/6] 下载 Node.js ──${NC}"

    if [ -f "${node_archive_path}" ]; then
        log_info "Node.js 压缩包已存在：${node_archive_path}"
    else
        log_info "正在下载 Node.js ${NODE_VERSION}..."

        if wget --no-check-certificate -O "${node_archive_path}" "${NODE_DOWNLOAD_URL}"; then
            log_success "Node.js 下载成功"
        else
            log_fail "Node.js 下载失败"
            rm -f "${node_archive_path}"
            return 1
        fi
    fi

    # ===== Step 2/4: 解压 Node.js + 配置环境变量 =====
    echo -e "\n${GREEN}── [2/6] 解压 Node.js 并配置环境变量 ──${NC}"

    if [ -d "${node_extract_dir}" ]; then
        log_info "Node.js 已解压，跳过"
    else
        log_info "正在解压 Node.js..."
        tar -xf "${node_archive_path}" -C "${node_env_dir}"
        if [ $? -eq 0 ]; then
            log_success "Node.js 解压成功"
        else
            log_fail "Node.js 解压失败"
            return 1
        fi
    fi

    # 配置环境变量（持久化 + 当前会话）
    sed -i '/# Claude Code 环境变量（由安装脚本添加）/,+4d' ~/.bashrc 2>/dev/null || true
    echo -e "\n# Claude Code 环境变量（由安装脚本添加）" >> ~/.bashrc
    echo "export PATH=${node_bin_dir}:\$PATH" >> ~/.bashrc
    echo "export NODE_TLS_REJECT_UNAUTHORIZED=0" >> ~/.bashrc
    echo "export IS_SANDBOX=1" >> ~/.bashrc
    echo "export CLAUDE_CODE_EFFORT_LEVEL=max" >> ~/.bashrc

    # 同步 Claude Code 环境变量到 /etc/profile.d/proxy.sh（登录 shell 生效；幂等：先删旧块再追加）
    local PROFILED_FILE="/etc/profile.d/proxy.sh"
    if touch "${PROFILED_FILE}" 2>/dev/null; then
        sed -i '/# Claude Code 环境变量（由安装脚本添加）/,+4d' "${PROFILED_FILE}" 2>/dev/null || true
        echo -e "\n# Claude Code 环境变量（由安装脚本添加）" >> "${PROFILED_FILE}"
        echo "export PATH=${node_bin_dir}:\$PATH" >> "${PROFILED_FILE}"
        echo "export NODE_TLS_REJECT_UNAUTHORIZED=0" >> "${PROFILED_FILE}"
        echo "export IS_SANDBOX=1" >> "${PROFILED_FILE}"
        echo "export CLAUDE_CODE_EFFORT_LEVEL=max" >> "${PROFILED_FILE}"
        chmod 644 "${PROFILED_FILE}" 2>/dev/null || true
        log_info "已同步 Claude Code 环境变量到 ${PROFILED_FILE}（登录 shell 生效）"

        # 代理块补偿同步：代理是此前就配好的（本次未走 setup_proxy_silent）时，
        # /etc/profile.d/proxy.sh 里不会有代理块 —— 用当前 shell 的代理值补写一次
        if [ -n "${https_proxy:-}" ] && ! grep -q '自动配置的代理（由安装脚本添加）' "${PROFILED_FILE}" 2>/dev/null; then
            sed -i '/http_proxy=/d;/https_proxy=/d;/no_proxy=/d;/GIT_SSL_NO_VERIFY=/d' "${PROFILED_FILE}" 2>/dev/null || true
            echo -e "\n# 自动配置的代理（由安装脚本添加）" >> "${PROFILED_FILE}"
            echo "export http_proxy=\"${http_proxy}\"" >> "${PROFILED_FILE}"
            echo "export https_proxy=\"${https_proxy}\"" >> "${PROFILED_FILE}"
            echo "export no_proxy=\"${no_proxy}\"" >> "${PROFILED_FILE}"
            echo "export GIT_SSL_NO_VERIFY=1" >> "${PROFILED_FILE}"
            chmod 644 "${PROFILED_FILE}" 2>/dev/null || true
            log_info "已补偿同步代理到 ${PROFILED_FILE}（此前 profile.d 缺代理块）"
        fi
    else
        log_warn "无 /etc/profile.d 写权限，Claude Code 环境变量仅写入 ~/.bashrc"
    fi

    export PATH=${node_bin_dir}:$PATH
    export NODE_TLS_REJECT_UNAUTHORIZED=0
    export IS_SANDBOX=1
    export CLAUDE_CODE_EFFORT_LEVEL=max

    if node -v > /dev/null 2>&1; then
        log_success "Node.js $(node -v) / npm $(npm -v)"
    else
        log_error "❌ Node.js 验证失败，检查 PATH 设置"
        log_info "Node.js 路径: ${node_bin_dir}"
        ls -la "${node_bin_dir}/" 2>/dev/null || log_error "目录不存在: ${node_bin_dir}"
        return 1
    fi

    # ===== Step 3/4: 安装 Claude Code =====
    echo -e "\n${GREEN}── [3/6] 安装 Claude Code ──${NC}"

    log_info "配置 npm 镜像源..."
    npm config set strict-ssl false
    npm config set registry "${NPM_REGISTRY}"
    npm cache clean -f 2>/dev/null || true

    log_info "正在安装 Claude Code（可能耗时 30-60 秒）..."

    if npm install -g "@anthropic-ai/claude-code" --verbose; then
        log_success "Claude Code 安装成功（$(claude -v 2>/dev/null || echo 'unknown')）"
    else
        log_warn "⚠️ 淘宝源安装失败，尝试切换腾讯云源..."
        npm config set registry "http://mirrors.cloud.tencent.com/npm/"
        if npm install -g "@anthropic-ai/claude-code" --verbose; then
            log_success "Claude Code 安装成功（腾讯云源）"
        else
            log_warn "⚠️ 腾讯云源也失败，尝试华为云源..."
            npm config set registry "https://mirrors.huaweicloud.com/repository/npm/"
            if npm install -g "@anthropic-ai/claude-code" --verbose; then
                log_success "Claude Code 安装成功（华为云源）"
            else
                log_fail "Claude Code 安装失败，请检查网络或手动安装"
                return 1
            fi
        fi
    fi

    # 验证 claude
    if command -v claude &> /dev/null; then
        log_info "Claude Code 版本: $(claude -v)"
    else
        log_warn "⚠️ claude 命令未在 PATH 中找到，尝试全路径验证..."
        if [ -f "${node_bin_dir}/claude" ]; then
            log_info "Claude Code 版本: $(${node_bin_dir}/claude -v)"
        else
            log_warn "claude 可执行文件未找到，请检查安装"
        fi
    fi

    # ===== Step 4/5: 配置状态栏脚本 statusline.py =====
    echo -e "\n${GREEN}── [4/6] 配置状态栏脚本 statusline.py ──${NC}"

    mkdir -p ~/.claude
    local STATUSLINE_SRC="${SCRIPT_DIR}/statusline.py"
    if [ -f "${STATUSLINE_SRC}" ]; then
        cp "${STATUSLINE_SRC}" ~/.claude/statusline.py
        chmod +x ~/.claude/statusline.py
        log_info "状态栏脚本已从 ${STATUSLINE_SRC} 复制到 ~/.claude/statusline.py"
    else
        log_warn "未找到 ${STATUSLINE_SRC}，跳过状态栏安装(请确认仓库文件完整)"
    fi

    # ===== Step 5/5: 配置 settings.json =====
    echo -e "\n${GREEN}── [5/6] 配置 Claude Code settings.json ──${NC}"

    # 检测 python3 绝对路径, 写入 statusLine command, 保证跨机器可用
    local CLAUDE_PYTHON
    CLAUDE_PYTHON="$(command -v python3 || command -v python)"
    if [ -z "${CLAUDE_PYTHON}" ]; then
        log_warn "未找到 python3，状态栏将回退使用 python3（请确保运行时 PATH 可用）"
        CLAUDE_PYTHON="python3"
    fi

    # API Key：默认沿用 ~/.claude/settings.json 已有的 Key（重装/升级场景），首次安装为占位符
    local CLAUDE_API_KEY="YOUR_API_KEY_HERE"
    if [ -f "$HOME/.claude/settings.json" ]; then
        local existing_key
        existing_key=$(grep -o '"ANTHROPIC_API_KEY"[^,}]*' "$HOME/.claude/settings.json" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/')
        [ -n "${existing_key}" ] && CLAUDE_API_KEY="${existing_key}"
    fi
    local input_api_key
    read -e -p "输入 ANTHROPIC_API_KEY（回车=保留原值/占位符）：" input_api_key
    input_api_key=$(echo "${input_api_key}" | xargs)
    [ -n "${input_api_key}" ] && CLAUDE_API_KEY="${input_api_key}"

    # 代理写入 settings.json env：非 bash 启动的 claude 进程（如 VS Code 面板子进程）也能出网
    local PROXY_ENV_LINES=""
    if [ -n "${https_proxy:-}" ]; then
        PROXY_ENV_LINES="    \"http_proxy\": \"${http_proxy}\",
    \"https_proxy\": \"${https_proxy}\",
    \"no_proxy\": \"${no_proxy}\",
"
    else
        log_warn "当前 shell 未设置 https_proxy，settings.json 将不注入代理（企业网内 VS Code 面板可能无法联网）"
    fi

    cat > ~/.claude/settings.json << EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://open.bigmodel.cn/api/anthropic",
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "1000000",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "glm-5.3[1m]",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-5.3[1m]",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5.3[1m]",
    "ANTHROPIC_API_KEY": "${CLAUDE_API_KEY}",
    "API_TIMEOUT_MS": "3000000",
    "CLAUDE_CODE_ATTRIBUTION_HEADER": "0",
${PROXY_ENV_LINES}    "NODE_TLS_REJECT_UNAUTHORIZED": "0",
    "GIT_SSL_NO_VERIFY": "1",
    "IS_SANDBOX": "1",
    "CLAUDE_CODE_EFFORT_LEVEL": "max"
  },
  "outputStyle": "engineer-professional",
  "skipDangerousModePermissionPrompt": true,
  "statusLine": {
    "type": "command",
    "command": "${CLAUDE_PYTHON} ${HOME}/.claude/statusline.py"
  }
}
EOF
    log_info "settings.json 已写入 ~/.claude/settings.json"
    if [ "${CLAUDE_API_KEY}" = "YOUR_API_KEY_HERE" ]; then
        log_warn "请修改 ~/.claude/settings.json 中的 ANTHROPIC_API_KEY 为你实际的 API Key"
    fi
    echo -e "${YELLOW}当前配置（API Key 已隐藏）:${NC}"
    sed 's/"ANTHROPIC_API_KEY": "[^"]*"/"ANTHROPIC_API_KEY": "<已隐藏>"/' ~/.claude/settings.json

    # ===== 写 ~/.claude.json：标记 onboarding 完成 + 开启第三方模型/fast mode =====
    # 本安装为中转配置（第三方模型 glm-5.3[1m]，不走 Anthropic OAuth），故合并写入两个字段：
    #   hasCompletedOnboarding=true —— 跳过首次启动的登录/新手引导
    #   penguinModeOrgEnabled=true  —— 开启第三方模型支持与 fast mode（沿用上游补丁脚本的同名字段）
    # 注意：~/.claude.json 与 ~/.claude/settings.json 是两个文件，且可能已有历史内容，需合并写入。
    # 用 node：此时 Node.js 已在本流程前面装好并在 PATH 上，且是 Claude Code 生态编辑该配置的惯用方式。
    if node <<'NODE'
const fs = require('fs'), path = require('path'), os = require('os');
const f = path.join(os.homedir(), '.claude.json');
let data = {};
try {
    data = fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, 'utf-8')) : {};
} catch (e) {
    if (fs.existsSync(f)) { try { fs.renameSync(f, f + '.bak-preinstall'); } catch (_) {} }  // 旧文件损坏：备份再重建
    data = {};
}
fs.writeFileSync(f, JSON.stringify({ ...data, penguinModeOrgEnabled: true, hasCompletedOnboarding: true }, null, 2), 'utf-8');
NODE
    then
        log_info "已写入 ~/.claude.json: hasCompletedOnboarding=true（跳过首次登录引导）、penguinModeOrgEnabled=true（第三方模型 + fast mode）"
    else
        log_warn "写入 ~/.claude.json 失败（不影响安装，首次启动 claude 可能需手动完成引导）"
    fi

    # ===== Step 6/6: 配置 VS Code 扩展（面板开箱即用）=====
    echo -e "\n${GREEN}── [6/6] 配置 VS Code 扩展（Machine 设置注入） ──${NC}"

    configure_claude_vscode_extension

    # ===== 配置终端桌宠（默认安装；汇总与「下一步」放到最后打印，确保留在屏幕上）=====
    install_clawd_pet

    # ===== 汇总 & 下一步（最后打印，确保留在屏幕上）=====
    echo
    log_success "Claude Code 安装完成"
    log_info "Node.js: $(node -v) | npm: $(npm -v) | Claude Code: $(claude -v 2>/dev/null || echo 'unavailable')"
    echo
    echo -e "${YELLOW}═══ 下一步（请按顺序操作）═══${NC}"
    echo -e "  1. ${RED}编辑 ~/.claude/settings.json${NC}，把 ANTHROPIC_API_KEY 由占位符 YOUR_API_KEY_HERE 改成你的真实 Key（安装时已输入则跳过）"
    echo -e "     ⚠️ 若之后更换 Key，需同步修改 ~/.vscode-server/data/Machine/settings.json（或重跑本安装脚本）"
    echo -e "  2. 让环境变量生效：${GREEN}source ~/.bashrc${NC}（或新开一个终端）"
    echo -e "  3. 启动：${GREEN}claude${NC}"
    echo -e "  4. VS Code 面板：安装 Claude Code 扩展后 Reload Window、新建对话即可直接使用（网关/代理配置已由脚本注入）"
    echo -e "     ⚠️ 笔记本本地 VS Code User 设置里若有旧的 claudeCode.environmentVariables（如 Kimi），已被本容器 Machine 设置覆盖，可放心保留"
    echo -e "  桌宠启动：${GREEN}bash ~/.claude/pet/start.sh${NC}（弹菜单选形象+布局；进入 tmux 主窗格运行 claude）"
    echo -e "${YELLOW}═══════════════════════════${NC}"
}

# ==================== Codex CLI 安装函数 ====================

# 测试 Codex 中转 URL，并记录 curl 结果供后续分类提示使用
codex_probe_relay_url() {
    local relay_url="$1"
    local curl_error_file
    local probe_output

    CODEX_CURL_EXIT=0
    CODEX_CURL_HTTP_CODE="000"
    CODEX_CURL_EFFECTIVE_URL=""
    CODEX_CURL_REDIRECT_URL=""
    CODEX_CURL_REMOTE_IP=""
    CODEX_CURL_SSL_VERIFY_RESULT=""
    CODEX_CURL_ERROR=""

    curl_error_file="$(mktemp)" || {
        CODEX_CURL_EXIT=2
        CODEX_CURL_ERROR="无法创建 curl 临时错误文件"
        return 2
    }

    probe_output="$(curl --location --silent --show-error \
        --connect-timeout 10 --max-time 20 --max-redirs 10 \
        --output /dev/null \
        --write-out '%{http_code}\t%{url_effective}\t%{redirect_url}\t%{remote_ip}\t%{ssl_verify_result}' \
        "${relay_url}" 2>"${curl_error_file}")"
    CODEX_CURL_EXIT=$?

    IFS=$'\t' read -r CODEX_CURL_HTTP_CODE \
        CODEX_CURL_EFFECTIVE_URL CODEX_CURL_REDIRECT_URL \
        CODEX_CURL_REMOTE_IP CODEX_CURL_SSL_VERIFY_RESULT <<< "${probe_output}"
    CODEX_CURL_HTTP_CODE="${CODEX_CURL_HTTP_CODE:-000}"
    CODEX_CURL_ERROR="$(tr '\n\r' '  ' < "${curl_error_file}")"
    CODEX_CURL_ERROR="${CODEX_CURL_ERROR:0:240}"
    rm -f "${curl_error_file}"

    return "${CODEX_CURL_EXIT}"
}

# 判断 curl 失败是否由证书或系统 CA 信任问题引起
codex_relay_ssl_error() {
    case "${CODEX_CURL_EXIT:-0}" in
        35|60|77)
            return 0
            ;;
    esac

    case "${CODEX_CURL_ERROR:-}" in
        *certificate*|*Certificate*|*SSL*|*CAfile*|*self-signed*|*unable\ to\ get\ local\ issuer*)
            return 0
            ;;
    esac
    return 1
}

# 解析中转 URL 的主机和端口，支持默认 HTTPS 端口及 IPv6 字面量
codex_parse_relay_endpoint() {
    local relay_url="$1"
    local authority remainder

    authority="${relay_url#*://}"
    authority="${authority%%/*}"
    authority="${authority%%\?*}"
    authority="${authority%%#*}"
    authority="${authority##*@}"

    CODEX_RELAY_HOST=""
    CODEX_RELAY_PORT=""

    if [[ "${authority}" == \[*\]* ]]; then
        CODEX_RELAY_HOST="${authority%%\]*}"
        CODEX_RELAY_HOST="${CODEX_RELAY_HOST#\[}"
        remainder="${authority#*\]}"
        if [[ "${remainder}" == :* ]]; then
            CODEX_RELAY_PORT="${remainder#:}"
        else
            CODEX_RELAY_PORT="443"
        fi
    elif [[ "${authority}" == *:* ]]; then
        CODEX_RELAY_HOST="${authority%%:*}"
        CODEX_RELAY_PORT="${authority##*:}"
    else
        CODEX_RELAY_HOST="${authority}"
        CODEX_RELAY_PORT="443"
    fi

    if [ -z "${CODEX_RELAY_HOST}" ] \
        || ! [[ "${CODEX_RELAY_PORT}" =~ ^[0-9]+$ ]] \
        || [ "${CODEX_RELAY_PORT}" -lt 1 ] \
        || [ "${CODEX_RELAY_PORT}" -gt 65535 ]; then
        return 1
    fi
    return 0
}

# 解码代理 URL 中的用户名和密码（与 ssl.sh 的处理方式一致）
codex_url_decode() {
    local encoded="${1//+/ }"
    printf '%b' "${encoded//%/\\x}"
}

# 提取证书 SHA-256 指纹，用于避免重复安装
codex_cert_fingerprint() {
    local cert_file="$1"
    openssl x509 -in "${cert_file}" -noout -fingerprint -sha256 2>/dev/null \
        | awk -F= 'NF > 1 {print $2}' \
        | tr -d ':' \
        | tr '[:lower:]' '[:upper:]'
}

# 集成 ssl.sh 的证书获取流程，直接在 HyperScript 内获取并安装中转站 CA
codex_fetch_relay_certificate() {
    local relay_url="$1"
    local proxy_var proxy_raw="" proxy_src="" proxy_url=""
    local proxy_auth="" proxy_addr="" proxy_host="" proxy_port=""
    local proxy_remainder proxy_user="" proxy_pass=""
    local openssl_help
    local connect_target
    local cert_temp_dir all_certs openssl_output openssl_error
    local openssl_exit=0
    local ca_dir="" ca_update_cmd=""
    local cert_file subject issuer fingerprint target_cert
    local installed_count=0
    local -a openssl_proxy_args=()

    if [[ "${relay_url}" != https://* ]]; then
        log_info "中转 URL 使用 HTTP，跳过 SSL 证书获取"
        return 0
    fi

    if ! command -v openssl >/dev/null 2>&1; then
        log_warn "当前环境未安装 openssl，无法自动获取中转站证书"
        return 1
    fi

    if ! codex_parse_relay_endpoint "${relay_url}"; then
        log_warn "无法解析中转 URL 的主机或端口，跳过证书获取"
        return 1
    fi

    # 复用 ssl.sh 的代理选择顺序，确保 openssl 与 curl 走同一条网络路径。
    for proxy_var in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy; do
        if [ -n "${!proxy_var:-}" ]; then
            proxy_raw="${!proxy_var}"
            proxy_src="${proxy_var}"
            break
        fi
    done

    if [ -n "${proxy_raw}" ]; then
        proxy_url="${proxy_raw#http://}"
        proxy_url="${proxy_url#https://}"
        proxy_url="${proxy_url%/}"

        if [[ "${proxy_url}" == *@* ]]; then
            proxy_auth="${proxy_url%@*}"
            proxy_addr="${proxy_url##*@}"
        else
            proxy_addr="${proxy_url}"
        fi
        proxy_addr="${proxy_addr%%/*}"

        if [[ "${proxy_addr}" == \[*\]* ]]; then
            proxy_host="${proxy_addr%%\]*}"
            proxy_host="${proxy_host#\[}"
            proxy_remainder="${proxy_addr#*\]}"
            if [[ "${proxy_remainder}" == :* ]]; then
                proxy_port="${proxy_remainder#:}"
            fi
        elif [[ "${proxy_addr}" == *:* ]]; then
            proxy_host="${proxy_addr%%:*}"
            proxy_port="${proxy_addr##*:}"
        else
            proxy_host="${proxy_addr}"
        fi

        if [ -z "${proxy_port}" ]; then
            if [[ "${proxy_raw}" == https://* ]]; then
                proxy_port="443"
            else
                proxy_port="80"
            fi
        fi

        if [ -z "${proxy_host}" ] || ! [[ "${proxy_port}" =~ ^[0-9]+$ ]]; then
            log_warn "无法解析 ${proxy_src} 代理地址，跳过证书获取"
            return 1
        fi

        openssl_help="$(openssl s_client -help 2>&1 || true)"
        if ! grep -qE '(^|[[:space:]])-proxy([[:space:]]|$)' <<< "${openssl_help}"; then
            log_warn "当前 openssl 不支持 s_client -proxy，无法通过 ${proxy_src} 获取证书"
            return 1
        fi
        openssl_proxy_args=(-proxy "${proxy_host}:${proxy_port}")

        if [ -n "${proxy_auth}" ]; then
            if [[ "${proxy_auth}" != *:* ]]; then
                log_warn "${proxy_src} 代理认证格式无效，跳过证书获取"
                return 1
            fi
            proxy_user="$(codex_url_decode "${proxy_auth%%:*}")"
            proxy_pass="$(codex_url_decode "${proxy_auth#*:}")"
            if [ -z "${proxy_user}" ] || [ -z "${proxy_pass}" ]; then
                log_warn "无法解析 ${proxy_src} 的代理用户名或密码，跳过证书获取"
                return 1
            fi
            if grep -q -- '-proxy_user' <<< "${openssl_help}"; then
                openssl_proxy_args+=(-proxy_user "${proxy_user}" -proxy_pass "pass:${proxy_pass}")
            else
                log_warn "当前 openssl 不支持代理认证参数，将尝试无认证连接"
                openssl_proxy_args=(-proxy "${proxy_host}:${proxy_port}")
            fi
        fi
    fi

    connect_target="${CODEX_RELAY_HOST}:${CODEX_RELAY_PORT}"
    if [[ "${CODEX_RELAY_HOST}" == *:* ]]; then
        connect_target="[${CODEX_RELAY_HOST}]:${CODEX_RELAY_PORT}"
    fi

    cert_temp_dir="$(mktemp -d)" || {
        log_warn "无法创建证书临时目录，跳过证书获取"
        return 1
    }
    all_certs="${cert_temp_dir}/all_certs.pem"
    openssl_output="${cert_temp_dir}/openssl.out"
    openssl_error="${cert_temp_dir}/openssl.err"

    log_warn "检测到 SSL 证书问题，正在获取 ${relay_url} 的证书..."
    if command -v timeout >/dev/null 2>&1; then
        timeout 15 openssl s_client "${openssl_proxy_args[@]}" \
            -connect "${connect_target}" \
            -servername "${CODEX_RELAY_HOST}" \
            -showcerts </dev/null > "${openssl_output}" 2>"${openssl_error}" \
            || openssl_exit=$?
    else
        openssl s_client "${openssl_proxy_args[@]}" \
            -connect "${connect_target}" \
            -servername "${CODEX_RELAY_HOST}" \
            -showcerts </dev/null > "${openssl_output}" 2>"${openssl_error}" \
            || openssl_exit=$?
    fi

    sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
        "${openssl_output}" > "${all_certs}"
    if [ ! -s "${all_certs}" ]; then
        log_warn "未获取到 ${relay_url} 的证书链，openssl 退出码 ${openssl_exit}"
        tail -n 3 "${openssl_error}" 2>/dev/null | sed 's/^/  /'
        rm -rf "${cert_temp_dir}"
        return 1
    fi

    awk -v out_dir="${cert_temp_dir}" '
        /-----BEGIN CERTIFICATE-----/ {
            n++;
            f=sprintf("%s/cert-%02d.pem", out_dir, n)
        }
        {
            if (f) print > f
        }
        /-----END CERTIFICATE-----/ {
            close(f)
            f=""
        }
    ' "${all_certs}"

    if command -v update-ca-trust >/dev/null 2>&1 \
        && [ -d /etc/pki/ca-trust/source/anchors ]; then
        ca_dir="/etc/pki/ca-trust/source/anchors"
        ca_update_cmd="update-ca-trust"
    elif command -v update-ca-certificates >/dev/null 2>&1; then
        ca_dir="/usr/local/share/ca-certificates"
        ca_update_cmd="update-ca-certificates"
    elif [ -d /etc/pki/ca-trust/source/anchors ]; then
        ca_dir="/etc/pki/ca-trust/source/anchors"
    else
        ca_dir="/usr/local/share/ca-certificates"
    fi

    if ! mkdir -p "${ca_dir}" 2>/dev/null || [ ! -w "${ca_dir}" ]; then
        log_warn "无法写入系统 CA 目录 ${ca_dir}，请检查权限"
        rm -rf "${cert_temp_dir}"
        return 1
    fi

    shopt -s nullglob
    for cert_file in "${cert_temp_dir}"/cert-*.pem; do
        subject="$(openssl x509 -in "${cert_file}" -noout -subject 2>/dev/null | sed 's/^subject=//')"
        issuer="$(openssl x509 -in "${cert_file}" -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
        if [ -z "${subject}" ] || [ "${subject}" != "${issuer}" ]; then
            continue
        fi

        fingerprint="$(codex_cert_fingerprint "${cert_file}")"
        [ -n "${fingerprint}" ] || continue
        target_cert="${ca_dir}/proxy-ca-${fingerprint}.crt"
        if [ -f "${target_cert}" ]; then
            continue
        fi

        if cp "${cert_file}" "${target_cert}"; then
            installed_count=$((installed_count + 1))
            log_info "已安装中转站 CA：${fingerprint}"
        else
            log_warn "写入 CA 失败：${target_cert}"
        fi
    done
    shopt -u nullglob

    if [ "${installed_count}" -eq 0 ]; then
        log_warn "证书链中未发现新的自签名 CA，系统信任库未修改"
        rm -rf "${cert_temp_dir}"
        return 1
    fi

    if [ "${ca_update_cmd}" = "update-ca-trust" ]; then
        if ! update-ca-trust extract; then
            log_warn "update-ca-trust 更新失败"
            rm -rf "${cert_temp_dir}"
            return 1
        fi
    elif [ "${ca_update_cmd}" = "update-ca-certificates" ]; then
        if ! update-ca-certificates; then
            log_warn "update-ca-certificates 更新失败"
            rm -rf "${cert_temp_dir}"
            return 1
        fi
    else
        log_warn "未找到系统 CA 更新命令，已写入 CA 文件但可能尚未生效"
    fi

    rm -rf "${cert_temp_dir}"
    log_success "中转站证书获取/更新完成"
    return 0
}

# 按 curl 退出码和 HTTP 状态报告中转站在当前环境的可用性
codex_report_relay_result() {
    local relay_url="$1"
    local curl_exit="${CODEX_CURL_EXIT:-1}"
    local http_code="${CODEX_CURL_HTTP_CODE:-000}"
    local effective_url="${CODEX_CURL_EFFECTIVE_URL:-}"
    local error_message="${CODEX_CURL_ERROR:-未知 curl 错误}"

    if [ "${curl_exit}" -ne 0 ]; then
        case "${curl_exit}" in
            6)
                log_error "中转站不可用：curl 无法解析域名（退出码 6）"
                ;;
            7)
                log_error "中转站不可用：curl 无法连接目标主机（退出码 7）"
                ;;
            28)
                log_error "中转站不可用：curl 连接或请求超时（退出码 28）"
                ;;
            35|60|77)
                log_error "中转站不可用：SSL/TLS 或系统 CA 证书校验失败（curl 退出码 ${curl_exit}）"
                ;;
            *)
                log_error "中转站不可用：curl 退出码 ${curl_exit}，${error_message}"
                ;;
        esac
        return 1
    fi

    if [ "${http_code}" = "504" ]; then
        log_error "中转站不可用：HTTP 504 Gateway Timeout"
        log_warn "如果该中转站位于内网，这通常表示当前环境无访问权限，请求已被防火墙重定向。"
        log_warn "这属于网络/防火墙问题，不是 API Key 校验失败。"
        if [ -n "${effective_url}" ] && [ "${effective_url}" != "${relay_url}" ]; then
            log_warn "curl 最终响应地址：${effective_url}"
        fi
        return 1
    fi

    case "${http_code}" in
        2??)
            log_success "中转站在当前环境可用（HTTP ${http_code}）"
            ;;
        3??)
            log_warn "中转站可访问，但最终返回 HTTP ${http_code}，请确认重定向后的地址是否为有效 API 地址"
            ;;
        401|403)
            log_warn "中转站在当前环境可访问（HTTP ${http_code}），但需要有效 API Key 或当前请求被拒绝"
            ;;
        404|405)
            log_warn "中转站主机在当前环境可访问，但 URL 路径可能不正确（HTTP ${http_code}）"
            ;;
        5??)
            log_error "中转站当前不可用：服务端返回 HTTP ${http_code}"
            ;;
        000)
            log_error "中转站不可用：curl 未获得 HTTP 响应（${error_message}）"
            ;;
        *)
            log_warn "中转站返回未分类的 HTTP 状态：${http_code}"
            ;;
    esac

    [[ "${http_code}" == 2?? || "${http_code}" == "401" || "${http_code}" == "403" ]]
}

# URL 首次测试失败且确认为证书问题时，获取证书后再次测试
codex_check_relay_url() {
    local relay_url="$1"

    log_info "正在测试中转 URL 可用性..."
    codex_probe_relay_url "${relay_url}" || true

    if codex_relay_ssl_error; then
        codex_fetch_relay_certificate "${relay_url}" || true
        log_info "证书处理完成，重新测试中转 URL..."
        codex_probe_relay_url "${relay_url}" || true
    else
        log_info "curl 未检测到 SSL 证书错误，跳过证书获取"
    fi

    codex_report_relay_result "${relay_url}"
}

# 安装 Codex CLI（Node.js + npm，含多源回退）
install_codex_cli() {
    local install_dir="${1:-$DEFAULT_CODEX_INSTALL_DIR}"

    echo -e "${GREEN}── 安装 Codex CLI ──${NC}"

    local NODE_VERSION="${DEFAULT_NODE_VERSION}"
    local NODE_PLATFORM
    if ! NODE_PLATFORM="$(detect_node_platform)"; then
        return 1
    fi
    local NODE_FILENAME="node-${NODE_VERSION}-${NODE_PLATFORM}.tar.gz"
    local NODE_DOWNLOAD_URL="${DEFAULT_NODE_MIRROR_BASE}/${NODE_VERSION}/${NODE_FILENAME}"
    local NPM_REGISTRY="${DEFAULT_NPM_REGISTRY}"
    local work_dir="${install_dir}"
    local node_env_dir="${work_dir}/codex_cli_env"
    local node_archive_path="${node_env_dir}/${NODE_FILENAME}"
    local node_extract_dir="${node_env_dir}/node-${NODE_VERSION}-${NODE_PLATFORM}"
    local node_bin_dir="${node_extract_dir}/bin"

    ensure_dir "${node_env_dir}"

    log_info "目录：${work_dir} | Node：${NODE_VERSION} (${NODE_PLATFORM}) | npm 源：${NPM_REGISTRY}"

    local confirm_install
    while true; do
        read -e -p "确认开始安装？(y/n，默认y)：" confirm_install
        confirm_install=$(echo "${confirm_install}" | xargs || echo "y")
        confirm_install=${confirm_install:-y}
        confirm_install=$(echo "${confirm_install}" | tr 'A-Z' 'a-z')
        if [[ "${confirm_install}" =~ ^[YyNn]$ ]]; then
            break
        else
            log_error "输入无效！请输入 y 或 n"
        fi
    done

    if [ "${confirm_install}" != "y" ]; then
        log_info "已取消安装"
        return 0
    fi

    # ===== Step 1/4: 下载 Node.js =====
    echo -e "\n${GREEN}── [1/4] 下载 Node.js ──${NC}"

    if [ -f "${node_archive_path}" ]; then
        log_info "Node.js 压缩包已存在：${node_archive_path}"
    else
        log_info "正在下载 Node.js ${NODE_VERSION}..."

        if wget --no-check-certificate -O "${node_archive_path}" "${NODE_DOWNLOAD_URL}"; then
            log_success "Node.js 下载成功"
        else
            log_fail "Node.js 下载失败"
            rm -f "${node_archive_path}"
            return 1
        fi
    fi

    # ===== Step 2/4: 解压 Node.js + 配置环境变量 =====
    echo -e "\n${GREEN}── [2/4] 解压 Node.js 并配置环境变量 ──${NC}"

    if [ -d "${node_extract_dir}" ]; then
        log_info "Node.js 已解压，跳过"
    else
        log_info "正在解压 Node.js..."
        tar -xf "${node_archive_path}" -C "${node_env_dir}"
        if [ $? -eq 0 ]; then
            log_success "Node.js 解压成功"
        else
            log_fail "Node.js 解压失败"
            return 1
        fi
    fi

    sed -i '/# Codex CLI 环境变量（由安装脚本添加）/,+2d' ~/.bashrc 2>/dev/null || true
    echo -e "\n# Codex CLI 环境变量（由安装脚本添加）" >> ~/.bashrc
    echo "export PATH=${node_bin_dir}:\$PATH" >> ~/.bashrc
    echo "export NODE_TLS_REJECT_UNAUTHORIZED=0" >> ~/.bashrc

    export PATH=${node_bin_dir}:$PATH
    export NODE_TLS_REJECT_UNAUTHORIZED=0

    if node -v > /dev/null 2>&1; then
        log_success "Node.js $(node -v) / npm $(npm -v)"
    else
        log_error "❌ Node.js 验证失败，检查 PATH 设置"
        log_info "Node.js 路径: ${node_bin_dir}"
        ls -la "${node_bin_dir}/" 2>/dev/null || log_error "目录不存在: ${node_bin_dir}"
        return 1
    fi

    # ===== Step 3/4: 安装 Codex CLI =====
    echo -e "\n${GREEN}── [3/4] 安装 Codex CLI ──${NC}"

    log_info "配置 npm 镜像源..."
    npm config set strict-ssl false
    npm config set registry "${NPM_REGISTRY}"
    npm cache clean -f 2>/dev/null || true

    log_info "正在安装 Codex CLI（可能耗时 30-60 秒）..."

    if npm install -g "${CODEX_PACKAGE}" --verbose; then
        log_success "Codex CLI 安装成功"
    else
        log_warn "⚠️ 淘宝源安装失败，尝试切换腾讯云源..."
        npm config set registry "http://mirrors.cloud.tencent.com/npm/"
        if npm install -g "${CODEX_PACKAGE}" --verbose; then
            log_success "Codex CLI 安装成功（腾讯云源）"
        else
            log_warn "⚠️ 腾讯云源也失败，尝试华为云源..."
            npm config set registry "https://mirrors.huaweicloud.com/repository/npm/"
            if npm install -g "${CODEX_PACKAGE}" --verbose; then
                log_success "Codex CLI 安装成功（华为云源）"
            else
                log_fail "Codex CLI 安装失败，请检查网络或手动安装"
                return 1
            fi
        fi
    fi

    if command -v codex &> /dev/null; then
        log_info "Codex CLI 版本: $(codex --version 2>/dev/null || echo 'unknown')"
    else
        log_warn "⚠️ codex 命令未在 PATH 中找到，尝试全路径验证..."
        if [ -f "${node_bin_dir}/codex" ]; then
            log_info "Codex CLI 版本: $(${node_bin_dir}/codex --version 2>/dev/null || echo 'unknown')"
        else
            log_warn "codex 可执行文件未找到，请检查安装"
        fi
    fi

    # ===== Step 4/4: 配置 ~/.codex/config.toml + .env =====
    echo -e "\n${GREEN}── [4/4] 配置 Codex CLI 配置文件 ──${NC}"

    local CODEX_DIR="${HOME}/.codex"
    mkdir -p "${CODEX_DIR}"

    local default_codex_base_url="${CODEX_BASE_URL:-$DEFAULT_CODEX_BASE_URL}"
    local user_base_url=""
    while true; do
        read -e -p "请输入 Codex 中转 URL（直接回车使用默认值 ${default_codex_base_url}）：" user_base_url
        user_base_url=$(echo "${user_base_url}" | xargs || true)
        user_base_url="${user_base_url:-${default_codex_base_url}}"
        if [[ "${user_base_url}" =~ ^https?://[^[:space:]\"]+$ ]]; then
            break
        fi
        log_error "中转 URL 无效，请输入以 http:// 或 https:// 开头的 URL"
        user_base_url=""
    done

    codex_check_relay_url "${user_base_url}" || true

    cat > "${CODEX_DIR}/config.toml" << TOML_EOF
model_provider = "OpenAI"
model = "gpt-5.6-sol"
review_model = "gpt-5.5"
model_reasoning_effort = "xhigh"
disable_response_storage = true
network_access = "enabled"
windows_wsl_setup_acknowledged = true
approval_policy = "never"
sandbox_mode="danger-full-access"
plan_mode_reasoning_effort = "xhigh"

[model_providers.OpenAI]
name = "OpenAI"
base_url = "${user_base_url}"
wire_api = "responses"
requires_openai_auth = true

[features]
goals = true
TOML_EOF
    log_info "config.toml 已写入 ${CODEX_DIR}/config.toml"

    echo
    echo -e "${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
    echo -e "${RED}!!! 警告：Codex CLI 已启用 YOLO 模式 !!!${NC}"
    echo -e "${RED}!!! approval_policy = \"never\"${NC}"
    echo -e "${RED}!!! sandbox_mode = \"danger-full-access\"${NC}"
    echo -e "${YELLOW}该模式会跳过审批，并允许 Codex 访问所有文件。${NC}"
    echo -e "${YELLOW}关闭方法：编辑 ${CODEX_DIR}/config.toml，将两项改为：${NC}"
    echo -e "  approval_policy = \"on-request\""
    echo -e "  sandbox_mode = \"workspace-write\""
    echo -e "${YELLOW}保存后重新启动 codex。${NC}"
    echo -e "${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"

    local OPENAI_API_KEY_PLACEHOLDER="YOUR_OPENAI_API_KEY_HERE"
    local user_api_key=""
    if [ -n "$OPENAI_API_KEY" ]; then
        log_info "检测到 OPENAI_API_KEY 环境变量已设置，将直接使用"
        user_api_key="${OPENAI_API_KEY}"
    else
        read -e -p "请输入你的 OpenAI API Key（直接回车使用占位符，稍后手动修改）：" user_api_key
        user_api_key=$(echo "${user_api_key}" | xargs || true)
    fi
    user_api_key="${user_api_key:-${OPENAI_API_KEY_PLACEHOLDER}}"

    cat > "${CODEX_DIR}/auth.json" << ENV_EOF
{
  "OPENAI_API_KEY": "${user_api_key}"
}
ENV_EOF
    log_info "auth.json 已写入 ${CODEX_DIR}/auth.json"

    if [ "${user_api_key}" = "${OPENAI_API_KEY_PLACEHOLDER}" ]; then
        log_warn "请修改 ${CODEX_DIR}/auth.json 中的 OPENAI_API_KEY 为你实际的 API Key"
        echo -e "${YELLOW}当前配置（API Key 使用占位符）:${NC}"
        cat "${CODEX_DIR}/auth.json"
    fi

    # ===== 汇总 =====
    echo
    log_success "Codex CLI 安装完成"
    log_info "Node.js: $(node -v) | npm: $(npm -v) | Codex CLI: $(codex --version 2>/dev/null || echo 'unavailable')"
    log_info "配置文件: ${CODEX_DIR}/config.toml | ${CODEX_DIR}/auth.json"
    log_info "新开的 Bash 终端会自动读取 ~/.bashrc"
    log_info "若希望当前终端立即加载，请手动执行: source ~/.bashrc"
    echo ""
    log_info "使用方法："
    echo -e "  ${GREEN}codex${NC}              - 启动 Codex CLI"
    echo -e "  ${GREEN}codex --help${NC}       - 查看帮助"
}

# ==================== 终端桌宠 (clawd-term / CodeNoNo) ====================

# 安装终端桌宠：tmux + Pillow + 脚本 + CodeNoNo 精灵图 + 注册 Claude Code hooks
install_clawd_pet() {
    echo -e "\n${GREEN}── 配置终端桌宠 (clawd-term · CodeNoNo) ──${NC}"
    local PET_DIR="${HOME}/.claude/pet"
    local SRC_DIR="${SCRIPT_DIR}/clawd-term"
    if [ -z "${SCRIPT_DIR:-}" ]; then
        SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-"$0"}")" 2>/dev/null && pwd)/clawd-term"
    fi

    # 1) 依赖：tmux / python3 / Pillow
    command -v tmux >/dev/null 2>&1 || {
        log_info "安装 tmux ..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -o Acquire::Retries=8 --no-install-recommends tmux >/dev/null 2>&1 \
            || { log_warn "tmux 安装失败，请手动 apt-get install tmux"; return 1; }
    }
    command -v python3 >/dev/null 2>&1 || { log_warn "缺少 python3"; return 1; }
    python3 -c "from PIL import Image" 2>/dev/null || {
        log_info "安装 Pillow ..."
        pip3 install -q -i https://pypi.tuna.tsinghua.edu.cn/simple pillow >/dev/null 2>&1 \
            || { log_warn "Pillow 安装失败，请手动 pip3 install pillow"; return 1; }
    }

    # 2) 拷贝桌宠脚本
    mkdir -p "$PET_DIR"
    if [ -d "$SRC_DIR" ]; then
        cp -f "$SRC_DIR"/pet.py "$SRC_DIR"/hook.sh "$SRC_DIR"/start.sh "$SRC_DIR"/merge_hooks.py "$PET_DIR/" 2>/dev/null
        chmod +x "$PET_DIR"/pet.py "$PET_DIR"/hook.sh "$PET_DIR"/start.sh 2>/dev/null
        log_info "桌宠脚本 -> ${PET_DIR}"
    else
        log_warn "未找到 ${SRC_DIR}（伴生 clawd-term/ 缺失），脚本拷贝跳过"
    fi

    # 3) 精灵图：codenono / bubu / yier -> ~/.claude/pet/<name>.webp（仓库自带 > 本地 awesome-codex-pet）
    local name DST DEV_P
    for name in codenono bubu yier; do
        DST="$PET_DIR/$name.webp"
        case "$name" in
            codenono) DEV_P="/home/l00889328/dev/awesome-codex-pet/pets/codenono--dq02/spritesheet.webp" ;;
            bubu)     DEV_P="/home/l00889328/dev/awesome-codex-pet/pets/bubu--gbn666/spritesheet.webp" ;;
            yier)     DEV_P="/home/l00889328/dev/awesome-codex-pet/pets/yier--gbn666/spritesheet.webp" ;;
        esac
        if [ -f "$DST" ]; then
            :
        elif [ -f "$SRC_DIR/$name.webp" ]; then
            cp -f "$SRC_DIR/$name.webp" "$DST"; log_info "精灵图 $name <- 仓库自带"
        elif [ -f "$DEV_P" ]; then
            cp -f "$DEV_P" "$DST"; log_info "精灵图 $name <- 本地 awesome-codex-pet"
        else
            log_warn "缺 $name.webp（可手动放到 $DST）"
        fi
    done

    # 4) 注册 Claude Code hooks（幂等，自动备份 settings.json.bak-pet）
    if [ -f "$PET_DIR/merge_hooks.py" ] && [ -f "${HOME}/.claude/settings.json" ]; then
        python3 "$PET_DIR/merge_hooks.py" >/dev/null 2>&1 \
            && log_info "hooks 已写入 ~/.claude/settings.json" \
            || log_warn "hooks 注册失败，可手动 python3 $PET_DIR/merge_hooks.py"
    fi

    echo
    log_success "终端桌宠配置完成"
    echo -e "  启动：${GREEN}bash ~/.claude/pet/start.sh${NC}（弹菜单选形象+布局）；或直接 ${GREEN}start.sh col${NC} / bottom / mid"
    echo -e "  进入 tmux 后在主窗格运行 ${GREEN}claude${NC}，桌宠随状态动；分离 Ctrl+B D。"
    echo -e "  清晰度/尺寸：编辑 ${YELLOW}~/.claude/pet/pet.py${NC} 顶部 ${YELLOW}PET_W${NC}（默认 40）。"
    echo -e "  内置 3 个形象（CodeNoNo/Bubu/Yi Er）：${GREEN}bash ~/.claude/pet/start.sh${NC} 弹菜单选；或 ${GREEN}PET_PET=bubu${NC}（/yier/codenono）直接指定。"
    echo -e "  翻看 claude 历史：经典模式滚轮/PgUp 翻不了——用 ${GREEN}/tui fullscreen${NC} 后 ${GREEN}PgUp/PgDn${NC}，或按 ${GREEN}Ctrl+O${NC} 进 transcript 审阅。"
}

# ==================== 菜单与主入口 ====================

# TUI 多选菜单（上下键导航，空格/x 多选，回车确认）
show_tui_menu() {
    local n=12
    local cursor=0
    local i key mark
    local node_platform

    node_platform="$(detect_node_platform 2>/dev/null)" || node_platform="未支持"

    # 选项列表
    local opt1="安装vllm"
    local opt2="安装vllm-ascend"
    local opt3="一键安装vllm+vllm-ascend"
    local opt4="创建vllm容器"
    local opt5="万能杀"
    local opt6="停止所有运行容器"
    local opt7="看看谁在用卡"
    local opt8="安装 Claude Code"
    local opt9="安装 Codex CLI"
    local opt10="安装终端桌宠（需先装 Claude Code）"
    local opt11="清除代理"
    local opt12="退出"

    # 选中状态（全局数组，0=未选 1=已选）
    _TUI_CHK=(0 0 0 0 0 0 0 0 0 0 0)

    tput civis 2>/dev/null  # 隐藏光标

    while true; do
        # 清屏重绘
        clear
        echo "=================================="
        echo -e "  ${GREEN}HyperScript 一键安装脚本${NC}"
        echo "=================================="
        echo -e "  ${YELLOW}当前默认配置（修改脚本顶部 DEFAULT_* 变量可调整）${NC}"
        printf "  ${GREEN}%-15s${NC} %s\n" "[代理]" "$DEFAULT_PROXY_IP:$DEFAULT_PROXY_PORT"
        printf "  ${GREEN}%-15s${NC} 分支 %s | 仓库 %s | 目录 %s\n" "[vllm]" "$DEFAULT_VLLM_BRANCH" "$DEFAULT_VLLM_REPO" "$DEFAULT_VLLM_INSTALL_DIR"
        printf "  ${GREEN}%-15s${NC} 分支 %s | 仓库 %s | 目录 %s\n" "[vllm-ascend]" "$DEFAULT_VLLM_ASCEND_BRANCH" "$DEFAULT_VLLM_ASCEND_REPO" "$DEFAULT_VLLM_ASCEND_INSTALL_DIR"
        printf "  ${GREEN}%-15s${NC} Node %s | npm %s | 目录 %s\n" "[Claude Code]" "$DEFAULT_NODE_VERSION ($node_platform)" "$DEFAULT_NPM_REGISTRY" "$DEFAULT_CLAUDE_CODE_INSTALL_DIR"
        printf "  ${GREEN}%-15s${NC} Node %s | npm %s | 包 %s\n" "[Codex CLI]" "$DEFAULT_NODE_VERSION ($node_platform)" "$DEFAULT_NPM_REGISTRY" "$CODEX_PACKAGE"
        printf "  ${GREEN}%-15s${NC} 容器 %s | 镜像 %s ${YELLOW}(创建新容器时的默认配置)${NC}\n" "[Docker]" "$DEFAULT_CONTAINER_NAME" "$DEFAULT_IMAGE_ID"
        echo "----------------------------------"
        for ((i=0; i<n; i++)); do
            case $i in
                0) desc="$opt1" ;; 1) desc="$opt2" ;; 2) desc="$opt3" ;;
                3) desc="$opt4" ;; 4) desc="$opt5" ;; 5) desc="$opt6" ;;
                6) desc="$opt7" ;; 7) desc="$opt8" ;; 8) desc="$opt9" ;;
                9) desc="$opt10" ;; 10) desc="$opt11" ;; 11) desc="$opt12" ;;
            esac
            if [ "${_TUI_CHK[$i]}" = "1" ]; then
                mark="✓"
            else
                mark=" "
            fi
            if [ $i -eq $cursor ]; then
                printf "\e[7m  [%s] %d. %s\e[0m\n" "$mark" "$((i+1))" "$desc"
            else
                printf "  [%s] %d. %s\n" "$mark" "$((i+1))" "$desc"
            fi
        done
        echo "=================================="
        echo -e "  ${YELLOW}↑↓ 移动 | 空格/x 选择 | Enter 确认 | a 全选 | q 退出${NC}"

        # 读取按键
        IFS= read -rsn1 key

        # 方向键：ESC [ A / ESC [ B
        if [[ "$key" == $'\x1b' ]]; then
            IFS= read -rsn2 -t 0.1 key
            if [[ "$key" == "[A" ]]; then
                ((cursor--)); [ $cursor -lt 0 ] && cursor=$((n-1))
            elif [[ "$key" == "[B" ]]; then
                ((cursor++)); [ $cursor -ge $n ] && cursor=0
            fi
            continue
        fi

        # 空格 或 x：切换选中
        if [[ "$key" == " " ]] || [[ "$key" == "x" ]]; then
            if [ "${_TUI_CHK[$cursor]}" = "1" ]; then
                _TUI_CHK[$cursor]=0
            else
                _TUI_CHK[$cursor]=1
            fi
            continue
        fi

        # Enter：确认
        if [[ "$key" == "" ]]; then
            break
        fi

        # a：全选（不含退出）
        if [[ "$key" == "a" ]]; then
            for ((i=0; i<n-1; i++)); do _TUI_CHK[$i]=1; done
            continue
        fi

        # q：退出
        if [[ "$key" == "q" ]]; then
            tput cnorm 2>/dev/null
            log_info "退出脚本"
            exit 0
        fi
    done

    tput cnorm 2>/dev/null  # 恢复光标

    # 输出选中项到全局数组
    TUI_SELECTED=()
    for ((i=0; i<n; i++)); do
        [ "${_TUI_CHK[$i]}" = "1" ] && TUI_SELECTED+=($((i+1)))
    done
}

# 主入口：环境检查 + 菜单循环
main() {
    check_command python3
    check_command pip
    check_command rm
    check_command cp
    check_command curl

    # 启动时检查网络连通性（配置信息已在菜单头部显示）
    ensure_network || exit 1

    while true; do
        show_tui_menu

        # 未选择任何项，重新显示菜单
        [ ${#TUI_SELECTED[@]} -eq 0 ] && continue

        for opt in "${TUI_SELECTED[@]}"; do
            case $opt in
                1)
                    install_vllm "$DEFAULT_VLLM_INSTALL_DIR" "$DEFAULT_VLLM_REPO" "$DEFAULT_VLLM_BRANCH"
                    ;;
                2)
                    install_vllm_ascend "$DEFAULT_VLLM_ASCEND_INSTALL_DIR" "$DEFAULT_VLLM_ASCEND_REPO" "$DEFAULT_VLLM_ASCEND_BRANCH"
                    ;;
                3)
                    install_vllm_all "$DEFAULT_VLLM_INSTALL_DIR"
                    ;;
                4)
                    create_vllm_container
                    ;;
                5)
                    kill_all_related_process
                    ;;
                6)
                    stop_all_containers
                    ;;
                7)
                    check_npu_occupancy
                    ;;
                8)
                    install_claude_code "$DEFAULT_CLAUDE_CODE_INSTALL_DIR"
                    ;;
                9)
                    install_codex_cli "$DEFAULT_CODEX_INSTALL_DIR"
                    ;;
                10)
                    install_clawd_pet
                    ;;
                11)
                    clear_proxy
                    ;;
                12)
                    log_info "退出脚本"
                    exit 0
                    ;;
            esac
        done

        echo
        read -e -p "按Enter键继续..."
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ $# -gt 0 ]; then
        # CLI 模式：非本地操作需要先检查网络
        case $1 in
            --stop-all-containers|--kill-all|--check-npu|--help)
                # 纯本地操作，跳过网络检查
                ;;
            *)
                ensure_network || exit 1
                ;;
        esac

        case $1 in
            --stop-all-containers)
                stop_all_containers
                exit 0
                ;;
            --kill-all)
                kill_all_related_process
                exit 0
                ;;
            --check-npu)
                check_npu_occupancy
                exit 0
                ;;
            --install-claude-code)
                install_claude_code "${2:-$DEFAULT_CLAUDE_CODE_INSTALL_DIR}"
                exit 0
                ;;
            --install-codex-cli)
                install_codex_cli "${2:-$DEFAULT_CODEX_INSTALL_DIR}"
                exit 0
                ;;
            --install-clawd-pet)
                install_clawd_pet
                exit 0
                ;;
            --install-vllm)
                install_vllm "${2:-$DEFAULT_VLLM_INSTALL_DIR}" "${3:-$DEFAULT_VLLM_REPO}" "${4:-$DEFAULT_VLLM_BRANCH}"
                exit 0
                ;;
            --install-vllm-ascend)
                install_vllm_ascend "${2:-$DEFAULT_VLLM_ASCEND_INSTALL_DIR}" "${3:-$DEFAULT_VLLM_ASCEND_REPO}" "${4:-$DEFAULT_VLLM_ASCEND_BRANCH}"
                exit 0
                ;;
            --install-vllm-all)
                install_vllm_all "${2:-$DEFAULT_VLLM_INSTALL_DIR}"
                exit 0
                ;;
            --help)
                echo "用法: $0 [选项]"
                echo "选项:"
                echo "  --check-npu                            查看NPU占用者"
                echo "  --install-vllm [DIR] [REPO] [BRANCH]   安装vllm（默认: 当前目录, $DEFAULT_VLLM_REPO, $DEFAULT_VLLM_BRANCH）"
                echo "  --install-vllm-ascend [DIR] [REPO] [BRANCH]  安装vllm-ascend（默认: 当前目录, $DEFAULT_VLLM_ASCEND_REPO, $DEFAULT_VLLM_ASCEND_BRANCH）"
                echo "  --install-vllm-all [DIR]               一键安装vllm+vllm-ascend（默认: 当前目录）"
                echo "  --install-claude-code [DIR]            安装Claude Code（末尾可选配置终端桌宠，内置 CodeNoNo/Bubu/Yi Er）"
                echo "  --install-codex-cli [DIR]              安装 Codex CLI（@openai/codex）"
                echo "  --install-clawd-pet                   单独安装终端桌宠（CodeNoNo/Bubu/Yi Er）"
                echo "  --help                                 显示此帮助信息"
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                echo "使用 --help 查看帮助信息"
                exit 1
                ;;
        esac
    else
        main "$@"
    fi
fi
