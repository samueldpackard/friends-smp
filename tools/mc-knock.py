#!/usr/bin/env python3
"""Pretend to be a player joining, and print what the server says.

Against a sleeping server the gateway answers "Waking up the server!" and starts it, so this
is how to wake the server (or test waking) without opening Minecraft.

Usage: tools/mc-knock.py [host] [port]      (default: the cloud server)
"""
import json, socket, struct, sys

HOST = sys.argv[1] if len(sys.argv) > 1 else "35.160.13.72"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 25565
PROTOCOL = 775  # any number works for a sleeping server; a running one just says "outdated"


def varint(n):
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        out += bytes([b | (0x80 if n else 0)])
        if not n:
            return out


def packet(pid, data):
    body = varint(pid) + data
    return varint(len(body)) + body


def string(s):
    b = s.encode()
    return varint(len(b)) + b


def read_varint(sock):
    n = shift = 0
    while True:
        b = sock.recv(1)
        if not b:
            raise EOFError
        n |= (b[0] & 0x7F) << shift
        shift += 7
        if not b[0] & 0x80:
            return n


with socket.create_connection((HOST, PORT), timeout=10) as s:
    s.sendall(packet(0, varint(PROTOCOL) + string(HOST) + struct.pack(">H", PORT) + varint(2)))
    s.sendall(packet(0, string("knock-test") + bytes(16)))  # Login Start: name + UUID
    length = read_varint(s)
    data = b""
    while len(data) < length:
        data += s.recv(length - len(data))
    pid, rest = data[0], data[1:]
    if pid == 0:  # Login Disconnect: JSON text
        i = 0
        while rest[i] & 0x80:
            i += 1
        msg = rest[i + 1:].decode(errors="replace")
        try:
            msg = json.loads(msg).get("text", msg)
        except (ValueError, AttributeError):
            pass
        print("Server says:", msg)
    else:
        print(f"Server answered with packet 0x{pid:02x} (it is up and handling logins)")
