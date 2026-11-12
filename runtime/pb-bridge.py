#!/usr/bin/env python3
"""Ponte hibrida para o PBLauncher sob Wine.

Motivo: o Wine manda HTTP puro na porta 443 (o Windows promove pra TLS sozinho).
Regra de iptables redireciona 443 dos hosts de patch para 8443.

Modo 1 (TLS, primeiro byte 0x16): tunel bruto para o destino original.
Modo 2 (HTTP): le o Host, abre TLS de verdade e devolve a resposta.
"""
import asyncio, socket, ssl, struct, sys

LISTEN = ("127.0.0.1", 8443)
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

SO_ORIGINAL_DST = 80


def log(*a):
    print(*a, flush=True)


def original_dst(sock):
    try:
        data = sock.getsockopt(socket.SOL_IP, SO_ORIGINAL_DST, 16)
        port = struct.unpack("!H", data[2:4])[0]
        ip = socket.inet_ntoa(data[4:8])
        return ip, port
    except Exception:
        return None, None


async def pump(src, dst):
    try:
        while True:
            data = await src.read(65536)
            if not data:
                break
            dst.write(data)
            await dst.drain()
    except Exception:
        pass
    finally:
        try:
            if dst.can_write_eof():
                dst.write_eof()
        except Exception:
            pass


async def tunel(reader, writer, ip, first):
    log(f"TLS  -> {ip}")
    r2, w2 = await asyncio.open_connection(ip, 443)
    w2.write(first)
    await w2.drain()
    await asyncio.gather(pump(reader, w2), pump(r2, writer))
    for w in (writer, w2):
        try:
            w.close()
        except Exception:
            pass


async def handle(reader, writer):
    try:
        sock = writer.get_extra_info("socket")
        ip, _ = original_dst(sock)

        first = await reader.read(1)
        if not first:
            writer.close()
            return

        if first[0] == 0x16:            # ClientHello TLS
            await tunel(reader, writer, ip, first)
            return

        head = first
        while b"\r\n\r\n" not in head:
            chunk = await reader.read(4096)
            if not chunk:
                writer.close()
                return
            head += chunk
        head_part, rest = head.split(b"\r\n\r\n", 1)
        lines = head_part.split(b"\r\n")
        method, uri, version = lines[0].decode("latin1").split(" ")

        host = None
        hdrs = []
        for l in lines[1:]:
            low = l.lower()
            if low.startswith(b"host:"):
                host = l.split(b":", 1)[1].strip().decode("latin1")
                continue
            if low.startswith((b"proxy-connection", b"connection", b"keep-alive")):
                continue
            hdrs.append(l)
        hdrs.append(b"Connection: close")

        if not host:
            host = ip
        name = host.split(":")[0]
        log(f"HTTP {method} {name}{uri}")

        r2, w2 = await asyncio.open_connection(name, 443, ssl=CTX, server_hostname=name)
        req = f"{method} {uri} {version}\r\nHost: {name}\r\n".encode("latin1")
        req += b"\r\n".join(hdrs) + b"\r\n\r\n"
        w2.write(req)
        if rest:
            w2.write(rest)
        await w2.drain()
        await pump(r2, writer)
        for w in (writer, w2):
            try:
                w.close()
            except Exception:
                pass
    except Exception as e:
        log("ERR", type(e).__name__, e)
        try:
            writer.close()
        except Exception:
            pass


async def main():
    srv = await asyncio.start_server(handle, *LISTEN)
    log(f"ponte ouvindo em {LISTEN[0]}:{LISTEN[1]}")
    async with srv:
        await srv.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
