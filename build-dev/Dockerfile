FROM ubuntu:22.04

# 环境变量：强制 UTF-8 编码，防止 ARM 下图标显示异常
ENV DEBIAN_FRONTEND=noninteractive \
    IN_CHINA=false \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

WORKDIR /root

COPY setup.sh /tmp/setup.sh
COPY entrypoint.sh /root/entrypoint.sh

RUN chmod +x /tmp/setup.sh /root/entrypoint.sh \
    && /tmp/setup.sh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

EXPOSE 22

ENTRYPOINT ["/root/entrypoint.sh"]

CMD ["/usr/sbin/sshd", "-D"]
