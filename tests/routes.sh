#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"
trap cleanup_root EXIT
fresh_root
export SB_SERVICE_MODE=process
"$CLI" add socks 28381 route-user route-pass >/dev/null
"$CLI" log debug
for address in 0.1.2.3 127.0.0.1 '[::1]' 10.0.0.1 100.64.0.1 192.0.2.1 198.18.0.1 \
    198.51.100.1 203.0.113.1 224.0.0.1 240.0.0.1 '[fc00::1]' '[64:ff9b:1::1]' \
    '[100::1]' '[2001:2::1]' '[2001:10::1]' '[2001:20::1]' '[2001:db8::1]' '[3fff::1]' '[fec0::1]' 114.114.114.114; do
    : > "$SB_ROOT/logs/core.log"
    must_fail curl --noproxy '' --silent --fail --max-time 4 --proxy socks5h://route-user:route-pass@127.0.0.1:28381 "http://$address:8000/"
    grep -q 'reject' "$SB_ROOT/logs/core.log" || { note "目标 $address 未在路由阶段拒绝"; cat "$SB_ROOT/logs/core.log" >&2; exit 1; }
    if grep -q 'outbound/direct' "$SB_ROOT/logs/core.log"; then die '被屏蔽的目标触发了出口拨号'; fi
done
pass 'real IPv4/IPv6 private, shared, reserved, benchmark and Chinese IP requests rejected before dialing'
cat > "$SB_ROOT/run/dns.py" <<'PY'
import socket,struct
sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
sock.bind(('127.0.0.1',28382))
while True:
 data,peer=sock.recvfrom(65535)
 end=12
 while data[end]:end+=1+data[end]
 end+=1
 qtype=struct.unpack('!H',data[end:end+2])[0]
 question=data[12:end+4]
 answer=b''
 if qtype==1:answer=b'\xc0\x0c'+struct.pack('!HHIH',1,1,30,4)+socket.inet_aton('114.114.114.114')
 sock.sendto(data[:2]+struct.pack('!HHHHH',0x8180,1,bool(answer),0,0)+question+answer,peer)
PY
python3 "$SB_ROOT/run/dns.py" &
dns_pid=$!
trap 'kill "$dns_pid" 2>/dev/null || true; cleanup_root' EXIT
sleep .1
"$CLI" dns set udp://127.0.0.1:28382
: > "$SB_ROOT/logs/core.log"
must_fail curl --noproxy '' --silent --fail --max-time 5 --proxy socks5h://route-user:route-pass@127.0.0.1:28381 http://cn-fixture.test:8000/
grep -q '114.114.114.114' "$SB_ROOT/logs/core.log"
grep -q 'reject' "$SB_ROOT/logs/core.log"
! grep -q 'outbound/direct' "$SB_ROOT/logs/core.log"
pass 'domain resolution precedes geoip filtering and never reaches a fallback outbound'
"$CLI" dns none
: > "$SB_ROOT/logs/core.log"
python3 - <<'PY'
import socket,struct,time
s=socket.create_connection(('127.0.0.1',28381),timeout=3)
s.sendall(b'\x05\x01\x02');assert s.recv(2)==b'\x05\x02'
s.sendall(b'\x01\x0aroute-user\x0aroute-pass');assert s.recv(2)==b'\x01\x00'
s.sendall(b'\x05\x01\x00\x01'+socket.inet_aton('9.9.9.9')+struct.pack('!H',8000))
s.recv(64)
s.sendall(b'\x13BitTorrent protocol'+b'\0'*8+b'a'*20+b'b'*20)
time.sleep(.5)
s.close()
PY
grep -qi 'bittorrent' "$SB_ROOT/logs/core.log"
grep -q 'reject' "$SB_ROOT/logs/core.log"
! grep -q 'outbound/direct' "$SB_ROOT/logs/core.log"
pass 'real BitTorrent handshake sniffed and rejected before outbound dial'
