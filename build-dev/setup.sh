#!/usr/bin/env bash
# 究极完全防爆版：Root 开发环境配置 (全套 Rust 工具链 + 全栈网络排障工具 + Ghostty 支持)

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

# 1. 基础系统与全栈网络排障工具
setup_base_system() {
  log_info "更新系统软件包并配置网络排障工具、压缩工具、SSH 及 NFS..."
  apt-get update -qq && env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  
  # 分类安装底层依赖，保持清晰
  env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget ca-certificates git vim build-essential jq tree htop fontconfig locales procps \
    ripgrep bat unzip pigz p7zip-full \
    iputils-ping net-tools iproute2 dnsutils netcat-openbsd traceroute mtr-tiny lsof tcpdump nmap \
    openssh-server nfs-common ncurses-bin
  
  locale-gen en_US.UTF-8
  mkdir -p /run/sshd
  
  # 强制 SSH 密钥登录
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
}

# --- 🚀 Ghostty Terminfo 自动注入 ---
install_ghostty_terminfo() {
  log_info "注入 Ghostty Terminfo (解决 SSH 远程渲染兼容性)..."
  local tmp_info=$(mktemp)
  if curl -fsSL "https://invisible-island.net/datafiles/current/terminfo.src.gz" | gzip -d > "${tmp_info}"; then
    tic -x "${tmp_info}" >/dev/null 2>&1 || true
    log_success "系统 Terminfo 数据库升级成功！原生支持 Ghostty/Kitty 等现代终端。"
  else
    log_info "⚠️ 未能拉取 terminfo 数据库，跳过。"
  fi
  rm -f "${tmp_info}"
}

# 2. Zsh 与 Oh My Zsh 框架
install_zsh_framework() {
  log_info "配置 Zsh 与补全插件..."
  env DEBIAN_FRONTEND=noninteractive apt-get install -y zsh
  chsh -s "$(command -v zsh)" root
  
  local omz_url=$(add_github_proxy 'https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh')
  curl -fsSL "${omz_url}" | RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh

  local custom_dir="${TARGET_HOME}/.oh-my-zsh/custom"
  mkdir -p "${custom_dir}/plugins" "${custom_dir}/completions"
  
  local plugins=("zsh-users/zsh-autosuggestions" "zsh-users/zsh-syntax-highlighting" "zsh-users/zsh-completions")
  for repo in "${plugins[@]}"; do
    git clone --depth=1 $(add_github_proxy "https://github.com/${repo}.git") "${custom_dir}/plugins/$(basename "$repo")"
  done
}

# 3. 现代二进制工具链 (动态版本追踪)
install_rust_tools() {
  log_info "安装现代二进制工具链 (Starship, Zellij, Eza, Zoxide, Yq, uv, fzf)..."
  local arch=$([[ "$(uname -m)" == "aarch64" ]] && echo "aarch64" || echo "x86_64")
  local arch_amd=$([[ "$(uname -m)" == "aarch64" ]] && echo "arm64" || echo "amd64")
  local tmp_dir=$(mktemp -d)

  # Starship & Zellij & Yq
  curl -fsSL $(add_github_proxy "https://github.com/starship/starship/releases/latest/download/starship-${arch}-unknown-linux-musl.tar.gz") | tar -xz -C /usr/local/bin starship
  curl -fsSL $(add_github_proxy "https://github.com/zellij-org/zellij/releases/latest/download/zellij-${arch}-unknown-linux-musl.tar.gz") | tar -xz -C /usr/local/bin zellij
  curl -fsSL $(add_github_proxy "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch_amd}") -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq
  
  # Eza
  curl -fsSL $(add_github_proxy "https://github.com/eza-community/eza/releases/latest/download/eza_${arch}-unknown-linux-gnu.tar.gz") | tar -xz -C "${tmp_dir}" && mv "${tmp_dir}/eza" /usr/local/bin/

  # Zoxide
  local z_tag=$(curl -sSLI -o /dev/null -w '%{url_effective}' "https://github.com/ajeetdsouza/zoxide/releases/latest" | awk -F/ '{print $NF}')
  local z_ver=${z_tag#v}
  curl -fsSL $(add_github_proxy "https://github.com/ajeetdsouza/zoxide/releases/download/${z_tag}/zoxide-${z_ver}-${arch}-unknown-linux-musl.tar.gz") | tar -xz -C "${tmp_dir}" && mv "${tmp_dir}/zoxide" /usr/local/bin/

  # uv (极速 Python 包管理)
  curl -LsSf https://astral.sh/uv/install.sh | sh
  mv "${TARGET_HOME}/.local/bin/uv" /usr/local/bin/
  mv "${TARGET_HOME}/.local/bin/uvx" /usr/local/bin/

  # fzf (防 404 及路径缺失修复)
  log_info "下载并修复 fzf..."
  local f_tag=$(curl -sSLI -o /dev/null -w '%{url_effective}' "https://github.com/junegunn/fzf/releases/latest" | awk -F/ '{print $NF}')
  local f_ver=${f_tag#v}
  local f_arch=$([[ "$arch_amd" == "amd64" ]] && echo "amd64" || echo "arm64")
  
  curl -fsSL $(add_github_proxy "https://github.com/junegunn/fzf/releases/download/${f_tag}/fzf-${f_ver}-linux_${f_arch}.tar.gz") | tar -xz -C /usr/local/bin fzf
  
  local fzf_plugin_dir="${TARGET_HOME}/.oh-my-zsh/custom/plugins/fzf-custom"
  mkdir -p "${fzf_plugin_dir}"
  curl -fsSL $(add_github_proxy "https://raw.githubusercontent.com/junegunn/fzf/master/shell/key-bindings.zsh") -o "${fzf_plugin_dir}/key-bindings.zsh"
  curl -fsSL $(add_github_proxy "https://raw.githubusercontent.com/junegunn/fzf/master/shell/completion.zsh") -o "${fzf_plugin_dir}/completion.zsh"
  
  rm -rf "$tmp_dir"
}

# 4. 开发语言环境与 Vim
install_dev_languages() {
  log_info "配置开发语言环境与 Vim..."
  
  # Node.js
  curl -fsSL https://deb.nodesource.com/setup_current.x | bash -
  env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  [[ "${IN_CHINA}" == "true" ]] && npm config set registry https://registry.npmmirror.com
  npm install -g @google/gemini-cli

  # Python3-pip, Go, JDK, DB clients
  env DEBIAN_FRONTEND=noninteractive apt-get install -y python3-pip default-jdk golang-go sqlite3 default-mysql-client redis-tools

  # Vim + Catppuccin
  git clone --depth=1 $(add_github_proxy 'https://github.com/amix/vimrc.git') "${TARGET_HOME}/.vim_runtime"
  sh "${TARGET_HOME}/.vim_runtime/install_awesome_vimrc.sh"
  git clone --depth=1 $(add_github_proxy 'https://github.com/catppuccin/vim.git') "${TARGET_HOME}/.vim_runtime/my_plugins/catppuccin-vim"
  echo -e 'if has("termguicolors")\n  set termguicolors\nendif\ncolorscheme catppuccin_latte\nset number\nset relativenumber' > "${TARGET_HOME}/.vim_runtime/my_configs.vim"
}

# 5. 写入最终配置
generate_final_configs() {
  log_info "生成环境核心配置文件..."
  mkdir -p "${TARGET_HOME}/Projects" "${TARGET_HOME}/.ssh" "${TARGET_HOME}/.config/zellij"
  chmod 700 "${TARGET_HOME}/.ssh"

  # Zellij
  echo -e 'theme "catppuccin-latte"\ndefault_layout "compact"\npane_frames false\nsimplified_ui true' > "${TARGET_HOME}/.config/zellij/config.kdl"

  # Zshrc
  cat > "${TARGET_HOME}/.zshrc" << 'EOF'
if ! infocmp "$TERM" >/dev/null 2>&1; then
    export TERM=xterm-256color
fi
export COLORTERM=truecolor

export ZSH="$HOME/.oh-my-zsh"
export LANG="en_US.UTF-8"
DISABLE_AUTO_UPDATE="true"

# 注意：移除了系统自带的 fzf 插件，通过下方 source 绝对路径防错
plugins=(git docker python pip npm zsh-completions zsh-autosuggestions zsh-syntax-highlighting)
fpath=($ZSH/custom/completions $fpath)

source $ZSH/oh-my-zsh.sh
eval "$(starship init zsh)"
eval "$(zoxide init zsh)"

# 手动加载 fzf 绑定，彻底告别 no such file 报错
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

# 常用网络排障别名
alias ports='netstat -tulanp'
EOF
}

main() {
  setup_base_system
  install_ghostty_terminfo
  install_zsh_framework
  install_rust_tools
  install_dev_languages
  generate_final_configs
  log_success "=== 究极版网络+开发全能沙箱构建完成 ==="
}

main "$@"
