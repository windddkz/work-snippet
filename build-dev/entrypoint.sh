#!/bin/bash
set -e

# 1. 自动生成 SSH 主机密钥 (避免容器启动时 sshd 崩溃)
ssh-keygen -A 2>/dev/null

# 2. 启动 SSH 守护进程 (在后台运行)
/usr/sbin/sshd

# 3. 将控制权交给 Dockerfile 中 CMD 指定的命令 (拉起 Zellij)
exec "$@"
