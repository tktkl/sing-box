"""Exercise real SOCKS5 UDP ASSOCIATE through a sing-box client."""
import socket
import struct
import sys


def receive(sock, length):
    data = b""
    while len(data) < length:
        part = sock.recv(length - len(data))
        if not part:
            raise RuntimeError("SOCKS connection closed")
        data += part
    return data


target = socket.gethostbyname(sys.argv[1])
control = socket.create_connection(("127.0.0.1", 1080), timeout=8)
control.sendall(b"\x05\x01\x00")
assert receive(control, 2) == b"\x05\x00"
control.sendall(b"\x05\x03\x00\x01" + b"\0" * 6)
header = receive(control, 4)
assert header[:2] == b"\x05\x00", header
if header[3] == 1:
    relay = socket.inet_ntoa(receive(control, 4))
elif header[3] == 4:
    relay = socket.inet_ntop(socket.AF_INET6, receive(control, 16))
else:
    relay = receive(control, receive(control, 1)[0]).decode()
port = struct.unpack("!H", receive(control, 2))[0]
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(8)
payload = b"sb-manager-udp-ok"
packet = b"\0\0\0\x01" + socket.inet_aton(target) + struct.pack("!H", 8001) + payload
sock.sendto(packet, (relay if relay != "0.0.0.0" else "127.0.0.1", port))
reply, _ = sock.recvfrom(65535)
assert reply.endswith(payload), reply
print("udp-ok")
