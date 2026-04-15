#!/bin/bash
set -e

# 1. 自动生成 SSH 主机密钥 (避免容器启动时 sshd 崩溃)
ssh-keygen -A 2>/dev/null

# 2. 将控制权移交给 Dockerfile 中 CMD 指定的命令 (此时将拉起 sshd -D)
exec "$@"
