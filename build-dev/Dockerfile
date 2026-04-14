FROM ubuntu:22.04

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

CMD ["/usr/local/bin/zellij"]
