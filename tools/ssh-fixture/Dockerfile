FROM alpine:3.22
RUN apk add --no-cache openssh-server python3 \
    && adduser -D fixture \
    && echo 'fixture:witerm-fixture-only' | chpasswd \
    && mkdir -p /etc/ssh/authorized_keys /run/sshd
COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh
EXPOSE 22
HEALTHCHECK --interval=2s --timeout=3s --retries=15 CMD python3 -c 'import socket; [socket.create_connection(("127.0.0.1",p),1).close() for p in (22,8081)]'
ENTRYPOINT ["/entrypoint.sh"]
