#!/bin/sh
set -eu
cp /keys/host /etc/ssh/witerm_host_ed25519
chmod 600 /etc/ssh/witerm_host_ed25519
cat /keys/client.pub /keys/encrypted.pub > /etc/ssh/authorized_keys/fixture
chmod 644 /etc/ssh/authorized_keys/fixture
# Fixed fixture only. No user shell, credentials, host folders or Docker socket.
python3 -u -c 'import socket
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",8081)); s.listen()
while True:
 c,_=s.accept()
 try:
  with c:
   while True:
    b=c.recv(65536)
    if not b: break
    c.sendall(b)
 except OSError:
  c.close()' &
exec /usr/sbin/sshd -D -e
