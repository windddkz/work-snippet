#!/usr/bin/env bash
# 究极完全版：ARM/AMD 兼容开发环境配置脚本 (Node/uv/Gemini/Rust-Tools/Catppuccin)

set -euo pipefail
trap 'echo -e "\033[0;31m[ERROR]\033[0m 第${LINENO}行命令执行失败：${BASH_COMMAND}"; exit 1' ERR

# --- 色彩与变量 ---
RED='\033[0;31m'; GREEN='\033[32;1m'; BLUE='\033[0;34m'; NC='\033[0m'
TARGET_HOME="/root"
IN_CHINA="${IN_CHINA:-true}"

log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

# 代理处理函数
add_github_proxy() {
  local url="$1"
  if [[ "${IN_CHINA}" == "true" && "${url}" =~ ^https://(github\.com|raw\.githubusercontent\.com) ]]; then
    echo "https://ghfast.top/${url}"
  else
    echo "${url}"
  fi
}

# 1. 基础系统与排障工具 (含 NFS 与终端编译库)
setup_base_system() {
  log_info "更新系统并安装基础工具、网络排障、压缩及 NFS 依赖..."
  apt-get update -qq && env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  
  env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget ca-certificates git vim build-essential jq tree htop fontconfig locales procps \
    ripgrep bat unzip pigz p7zip-full \
    iputils-ping net-tools iproute2 dnsutils netcat-openbsd traceroute mtr-tiny lsof tcpdump nmap \
    openssh-server nfs-common ncurses-bin
  
  locale-gen en_US.UTF-8
  mkdir -p /run/sshd
  
  # 强制 SSH 密钥登录配置
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
}

# 2. 现代终端数据库注入 (解决 Ghostty 兼容性)
install_modern_terminfos() {
  log_info "注入最新终端渲染库..."
  local tmp_info=$(mktemp)
  if curl -fsSL "https://invisible-island.net/datafiles/current/terminfo.src.gz" | gzip -d > "${tmp_info}"; then
    tic -x "${tmp_info}" >/dev/null 2>&1 || true
    log_success "Terminfo 升级成功。"
  fi
  rm -f "${tmp_info}"
}

# 3. Zsh 与插件
install_zsh_framework() {
  log_info "配置 Zsh 框架..."
  env DEBIAN_FRONTEND=noninteractive apt-get install -y zsh
  chsh -s "$(command -v zsh)" root
  
  local omz_url=$(add_github_proxy 'https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh')
  curl -fsSL "${omz_url}" | RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh

  local custom_dir="${TARGET_HOME}/.oh-my-zsh/custom"
  mkdir -p "${custom_dir}/plugins"
  local plugins=("zsh-users/zsh-autosuggestions" "zsh-users/zsh-syntax-highlighting" "zsh-users/zsh-completions")
  for repo in "${plugins[@]}"; do
    git clone --depth=1 $(add_github_proxy "https://github.com/${repo}.git") "${custom_dir}/plugins/$(basename "$repo")"
  done
}

# 4. 跨架构二进制工具链安装 (核心逻辑)
install_rust_tools() {
  log_info "识别系统架构并下载二进制工具链..."
  local raw_arch=$(uname -m)
  local arch=""      # 用于大部分 rust 二进制 (aarch64 / x86_64)
  local arch_alt=""  # 用于 yq/fzf (arm64 / amd64)
  
  if [[ "$raw_arch" == "aarch64" || "$raw_arch" == "arm64" ]]; then
      arch="aarch64"
      arch_alt="arm64"
  else
      arch="x86_64"
      arch_alt="amd64"
  fi

  local tmp_dir=$(mktemp -d)

  # Starship & Zellij
  curl -fsSL $(add_github_proxy "https://github.com/starship/starship/releases/latest/download/starship-${arch}-unknown-linux-musl.tar.gz") | tar -xz -C /usr/local/bin starship
  curl -fsSL $(add_github_proxy "https://github.com/zellij-org/zellij/releases/latest/download/zellij-${arch}-unknown-linux-musl.tar.gz") | tar -xz -C /usr/local/bin zellij
  
  # Yq (ARM 特殊后缀)
  curl -fsSL $(add_github_proxy "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch_alt}") -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq
  
  # Eza (ARM 特殊后缀)
  curl -fsSL $(add_github_proxy "https://github.com/eza-community/eza/releases/latest/download/eza_${arch}-unknown-linux-gnu.tar.gz") | tar -xz -C "${tmp_dir}" && mv "${tmp_dir}/eza" /usr/local/bin/

  # Zoxide (动态追踪版本)
  local z_tag=$(curl -sSLI -o /dev/null -w '%{url_effective}' "https://github.com/ajeetdsouza/zoxide/releases/latest" | awk -F/ '{print $NF}')
  local z_ver=${z_tag#v}
  curl -fsSL $(add_github_proxy "https://github.com/ajeetdsouza/zoxide/releases/download/${z_tag}/zoxide-${z_ver}-${arch}-unknown-linux-musl.tar.gz") | tar -xz -C "${tmp_dir}" && mv "${tmp_dir}/zoxide" /usr/local/bin/

  # fzf (ARM 特殊后缀)
  local f_tag=$(curl -sSLI -o /dev/null -w '%{url_effective}' "https://github.com/junegunn/fzf/releases/latest" | awk -F/ '{print $NF}')
  local f_ver=${f_tag#v}
  curl -fsSL $(add_github_proxy "https://github.com/junegunn/fzf/releases/download/${f_tag}/fzf-${f_ver}-linux_${arch_alt}.tar.gz") | tar -xz -C /usr/local/bin fzf
  
  # fzf 绑定脚本
  local fzf_plugin_dir="${TARGET_HOME}/.oh-my-zsh/custom/plugins/fzf-custom"
  mkdir -p "${fzf_plugin_dir}"
  curl -fsSL $(add_github_proxy "https://raw.githubusercontent.com/junegunn/fzf/master/shell/key-bindings.zsh") -o "${fzf_plugin_dir}/key-bindings.zsh"
  curl -fsSL $(add_github_proxy "https://raw.githubusercontent.com/junegunn/fzf/master/shell/completion.zsh") -o "${fzf_plugin_dir}/completion.zsh"

  # uv
  curl -LsSf https://astral.sh/uv/install.sh | sh
  mv "${TARGET_HOME}/.local/bin/uv" /usr/local/bin/
  mv "${TARGET_HOME}/.local/bin/uvx" /usr/local/bin/

  rm -rf "$tmp_dir"
}

# 5. Node, Python, Go 与 Vim 配置
install_dev_envs() {
  log_info "安装开发语言环境..."
  curl -fsSL https://deb.nodesource.com/setup_current.x | bash -
  env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  [[ "${IN_CHINA}" == "true" ]] && npm config set registry https://registry.npmmirror.com
  npm install -g @google/gemini-cli
  env DEBIAN_FRONTEND=noninteractive apt-get install -y python3-pip default-jdk golang-go sqlite3 default-mysql-client redis-tools

  # Vim + Catppuccin
  git clone --depth=1 $(add_github_proxy 'https://github.com/amix/vimrc.git') "${TARGET_HOME}/.vim_runtime"
  sh "${TARGET_HOME}/.vim_runtime/install_awesome_vimrc.sh"
  git clone --depth=1 $(add_github_proxy 'https://github.com/catppuccin/vim.git') "${TARGET_HOME}/.vim_runtime/my_plugins/catppuccin-vim"
  echo -e 'if has("termguicolors")\n  set termguicolors\nendif\ncolorscheme catppuccin_latte\nset number\nset relativenumber' > "${TARGET_HOME}/.vim_runtime/my_configs.vim"
}

# 6. 生成最终配置 (含最重要的终端自适应逻辑)
generate_final_configs() {
  log_info "写入 Zshrc 与 Zellij 最终配置..."
  mkdir -p "${TARGET_HOME}/Projects" "${TARGET_HOME}/.ssh" "${TARGET_HOME}/.config/zellij"
  chmod 700 "${TARGET_HOME}/.ssh"

  echo -e 'theme "catppuccin-latte"\ndefault_layout "compact"\npane_frames false\nsimplified_ui true' > "${TARGET_HOME}/.config/zellij/config.kdl"

  cat > "${TARGET_HOME}/.zshrc" << 'EOF'
# --- 终端自适应兼容性防御 ---
if ! infocmp "$TERM" >/dev/null 2>&1; then
    export TERM=xterm-256color
fi
export COLORTERM=truecolor

export ZSH="$HOME/.oh-my-zsh"
export LANG="en_US.UTF-8"
DISABLE_AUTO_UPDATE="true"

plugins=(git docker python pip npm zsh-completions zsh-autosuggestions zsh-syntax-highlighting)
fpath=($ZSH/custom/completions $fpath)

source $ZSH/oh-my-zsh.sh
eval "$(starship init zsh)"
eval "$(zoxide init zsh)"

source ~/.oh-my-zsh/custom/plugins/fzf-custom/completion.zsh
source ~/.oh-my-zsh/custom/plugins/fzf-custom/key-bindings.zsh

alias ls='eza --icons=always --color=always --group-directories-first'
alias ll='eza -al --icons=always --color=always --group-directories-first'
alias cat='batcat --paging=never -p'
alias cd='z'
alias zj='zellij'
alias zja='zellij attach'
alias d='docker'
alias dc='docker compose'
alias dps='docker ps -a'
alias proj='cd ~/Projects'
alias pip='uv pip'
alias venv='uv venv'
EOF
}

main() {
  setup_base_system
  install_modern_terminfos
  install_zsh_framework
  install_rust_tools
  install_dev_envs
  generate_final_configs
  log_success "=== 究极 ARM/AMD 开发沙箱配置完毕 ==="
}

main "$@"
