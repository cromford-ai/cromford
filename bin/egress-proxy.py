#!/usr/bin/env python3
"""bin/egress-proxy.py — the egress allowlist fence for build stages (BH-4492,
wave 5 of BH-4475).

bin/lib/egress.sh runs a build stage's runner inside a fresh network namespace
(`unshare -n`). Inside it there is only loopback, so the one way out is a unix
socket this script serves from OUTSIDE the namespace. Four modes:

  serve --sock P --stage S --log F --hosts LIST --id ID
      The allowlisting proxy, outside the namespace. `CONNECT host:port` gets a
      tunnel and an absolute-form `GET http://host[:port]/...` is forwarded,
      only when host:port matches LIST; anything else is answered 403 and
      logged as `<iso> stage=S DENY host:port via=proxy id=ID`. Every request
      line on a plain-HTTP connection is checked, not only the first. On TERM
      it appends `<iso> stage=S END allow=N deny=N id=ID`. It exits when its
      parent does.
  inner --sock P --stage S --log F --id ID -- CMD...
      Runs as the first process inside the namespace. Brings lo up, routes
      every address to lo (so a connect that ignores the proxy env lands on a
      catch listener and is logged `DENY-DIRECT ip:port via=direct`), forwards
      127.0.0.1:3128 to the socket, sets the proxy env, and runs CMD as its
      child with CAP_SYS_ADMIN and CAP_NET_ADMIN dropped from the bounding set
      (so a root agent cannot setns back out or rewire the namespace). Exits
      with CMD's rc; on exit appends `END-INNER direct=N`.
  fwd --listen HOST:PORT --sock P --port-file F
      The same forwarder in the current namespace (the unprivileged tests).
  match --hosts LIST host:port
      rc 0 when LIST allows host:port, 1 when it does not.

LIST is space/comma separated: `host` (ports 443 and 80), `*.suffix`
(subdomains only, never the bare suffix), `host:port` (that port only). An IP
literal matches only an exact entry. The log carries host:port only — never a
request line, a header or a body. At most 500 DENY lines per process, then one
DENY-CAPPED line; the END counters stay exact.

Python 3 stdlib only.
"""
import argparse
import asyncio
import ctypes
import ipaddress
import os
import re
import shutil
import signal
import socket
import struct
import sys
import time

DENY_LOG_CAP = 500
PROXY_PORT = 3128
CATCH_PORTS = (80, 443)
HEAD_MAX = 16384
CONNECT_TIMEOUT_S = 10
READ_TIMEOUT_S = 15
BODY_MAX = 1024 * 1024
MAX_CONNECTIONS = 64
STREAM_IDLE_S = 120


def now():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


def safe(text, n=253):
    """Host text as it may be logged: no whitespace or control chars, bounded."""
    text = re.sub(r'[\x00-\x20\x7f]', '', str(text))
    return text[:n]


class Log:
    def __init__(self, path, stage, ident):
        self.path, self.stage, self.ident = path, safe(stage, 40), safe(ident, 40)
        self.deny_lines = 0
        self.capped = False

    def write(self, rest):
        line = f'{now()} stage={self.stage} {rest} id={self.ident}\n'
        try:
            fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
            try:
                os.write(fd, line.encode('utf-8', 'replace'))
            finally:
                os.close(fd)
        except OSError:
            pass

    def deny(self, kind, target, via):
        if self.deny_lines < DENY_LOG_CAP:
            self.deny_lines += 1
            self.write(f'{kind} {safe(target)} via={via}')
        elif not self.capped:
            self.capped = True
            self.write(f'DENY-CAPPED after {DENY_LOG_CAP} lines; the END counts stay exact')


# --- the allowlist ------------------------------------------------------------

def parse_hosts(text):
    out = []
    for raw in re.split(r'[\s,]+', text or ''):
        e = raw.strip().lower()
        if not e:
            continue
        port = None
        m = re.match(r'^(.*):([0-9]{1,5})$', e)
        if m:
            e, port = m.group(1), int(m.group(2))
        out.append((e.rstrip('.'), port))
    return out


def is_ip(host):
    try:
        ipaddress.ip_address(host.strip('[]'))
        return True
    except ValueError:
        return False


def allowed(host, port, entries):
    h = host.lower().rstrip('.')
    for pat, p in entries:
        if p is None and port not in (80, 443):
            continue
        if p is not None and port != p:
            continue
        if pat.startswith('*.'):
            suffix = pat[1:]
            if not is_ip(h) and h.endswith(suffix) and len(h) > len(suffix):
                return True
        elif h == pat:
            return True
    return False


def split_hostport(authority, default_port):
    """`host[:port]` / `[v6]:port` -> (host, port); None when malformed."""
    a = authority.strip()
    if a.startswith('['):
        end = a.find(']')
        if end < 0:
            return None
        host, rest = a[:end + 1], a[end + 1:]
        if rest and not rest.startswith(':'):
            return None
        port = rest[1:] if rest else ''
    elif a.count(':') == 1:
        host, port = a.split(':')
    else:
        host, port = a, ''
    if not host:
        return None
    if port == '':
        return host, default_port
    if not port.isdigit() or not 0 < int(port) < 65536:
        return None
    return host, int(port)


# --- serve ----------------------------------------------------------------------

class Proxy:
    def __init__(self, entries, log):
        self.entries, self.log = entries, log
        self.allow = 0
        self.deny = 0
        self.active = 0

    async def refuse(self, writer, host, port, stage):
        self.deny += 1
        # Logged BEFORE the answer, so a refusal is never unlogged.
        self.log.deny('DENY', f'{host}:{port}', 'proxy')
        body = (f'egress refused: {safe(host)}:{port} is not on the {stage} allowlist '
                f'(settings row egress.stage.{stage}.hosts)\n').encode()
        writer.write(b'HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nConnection: close\r\n'
                     + f'Content-Length: {len(body)}\r\n\r\n'.encode() + body)
        try:
            await writer.drain()
        except OSError:
            pass

    async def bad(self, writer, code, why):
        writer.write(f'HTTP/1.1 {code} {why}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n'.encode())
        try:
            await writer.drain()
        except OSError:
            pass

    async def upstream(self, host, port):
        return await asyncio.wait_for(asyncio.open_connection(host.strip('[]'), port),
                                      CONNECT_TIMEOUT_S)

    async def handle(self, reader, writer):
        admitted = False
        try:
            if self.active >= MAX_CONNECTIONS:
                return await self.bad(writer, 503, 'Service Unavailable')
            self.active += 1
            admitted = True
            await self._handle(reader, writer)
        except asyncio.TimeoutError:
            await self.bad(writer, 408, 'Request Timeout')
        except asyncio.LimitOverrunError:
            await self.bad(writer, 431, 'Request Header Fields Too Large')
        except (OSError, asyncio.IncompleteReadError, ValueError):
            pass
        finally:
            if admitted:
                self.active -= 1
            try:
                writer.close()
            except OSError:
                pass

    async def _handle(self, reader, writer):
        stage = self.log.stage
        while True:
            try:
                head = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), READ_TIMEOUT_S)
            except asyncio.IncompleteReadError:
                return
            if len(head) > HEAD_MAX:
                return await self.bad(writer, 431, 'Request Header Fields Too Large')
            lines = head.decode('latin-1').split('\r\n')
            parts = lines[0].split(' ')
            if len(parts) != 3:
                return await self.bad(writer, 400, 'Bad Request')
            method, target, version = parts
            if version not in ('HTTP/1.0', 'HTTP/1.1') or not re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", method):
                return await self.bad(writer, 400, 'Bad Request')
            headers = [h for h in lines[1:] if h]
            low = []
            for h in headers:
                name, sep, value = h.partition(':')
                if not sep or not re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", name) or re.search(r'[\x00-\x08\x0a-\x1f\x7f]', value):
                    return await self.bad(writer, 400, 'Bad Request')
                low.append(name.lower())
            if low.count('content-length') > 1 or low.count('host') > 1:
                return await self.bad(writer, 400, 'Bad Request')
            if 'transfer-encoding' in low:
                return await self.bad(writer, 501, 'Not Implemented')
            length = 0
            host_header = None
            for name, h in zip(low, headers):
                value = h.split(':', 1)[1].strip()
                if name == 'host':
                    host_header = value
                elif name == 'content-length':
                    if not re.fullmatch(r'[0-9]{1,20}', value):
                        return await self.bad(writer, 400, 'Bad Request')
                    length = int(value)
            if length > BODY_MAX:
                return await self.bad(writer, 413, 'Content Too Large')
            if method.upper() == 'CONNECT':
                if length:
                    return await self.bad(writer, 400, 'Bad Request')
                hp = split_hostport(target, 443)
                if hp is None:
                    return await self.bad(writer, 400, 'Bad Request')
                host, port = hp
                if not allowed(host, port, self.entries):
                    return await self.refuse(writer, host, port, stage)
                self.allow += 1
                try:
                    ur, uw = await self.upstream(host, port)
                except (OSError, asyncio.TimeoutError):
                    self.log.write(f'ERR {safe(host)}:{port} upstream-unreachable')
                    return await self.bad(writer, 502, 'Bad Gateway')
                try:
                    writer.write(b'HTTP/1.1 200 Connection Established\r\n\r\n')
                    await asyncio.wait_for(writer.drain(), READ_TIMEOUT_S)
                    await pipe_both(reader, writer, ur, uw)
                finally:
                    uw.close()
                return
            m = re.match(r'^http://([^/?#]+)(.*)$', target, re.I)
            if not m:
                return await self.bad(writer, 400, 'Bad Request')
            hp = split_hostport(m.group(1), 80)
            if hp is None:
                return await self.bad(writer, 400, 'Bad Request')
            host, port = hp
            host = host.lower().rstrip('.')
            if not allowed(host, port, self.entries):
                return await self.refuse(writer, host, port, stage)
            supplied = split_hostport(host_header, 80) if host_header is not None else None
            if (version == 'HTTP/1.1' and supplied is None) or (host_header is not None and
                    (supplied is None or (supplied[0].lower().rstrip('.'), supplied[1]) != (host, port))):
                return await self.bad(writer, 400, 'Bad Request')
            body = await asyncio.wait_for(reader.readexactly(length), READ_TIMEOUT_S) if length else b''
            self.allow += 1
            try:
                ur, uw = await self.upstream(host, port)
            except (OSError, asyncio.TimeoutError):
                self.log.write(f'ERR {safe(host)}:{port} upstream-unreachable')
                return await self.bad(writer, 502, 'Bad Gateway')
            # One upstream connection per request, closed by the upstream after
            # its response: the NEXT request line on this client connection is
            # read and checked again here, never passed through blind.
            keep = [h for n, h in zip(low, headers)
                    if n not in ('host', 'connection', 'proxy-connection', 'keep-alive', 'proxy-authorization')]
            # The HTTP virtual host is the same authority that passed the allowlist.
            keep.append(f'Host: {host}' + (f':{port}' if port != 80 else ''))
            path = m.group(2) or '/'
            req = f'{method} {path} {version}\r\n' + ''.join(h + '\r\n' for h in keep) + 'Connection: close\r\n\r\n'
            try:
                uw.write(req.encode('latin-1') + body)
                await asyncio.wait_for(uw.drain(), READ_TIMEOUT_S)
                while True:
                    d = await asyncio.wait_for(ur.read(65536), STREAM_IDLE_S)
                    if not d:
                        break
                    writer.write(d)
                    await asyncio.wait_for(writer.drain(), STREAM_IDLE_S)
            finally:
                uw.close()


async def pipe(reader, writer):
    try:
        while True:
            d = await asyncio.wait_for(reader.read(65536), STREAM_IDLE_S)
            if not d:
                break
            writer.write(d)
            await asyncio.wait_for(writer.drain(), STREAM_IDLE_S)
    except (OSError, asyncio.IncompleteReadError, asyncio.TimeoutError):
        pass
    finally:
        try:
            if writer.can_write_eof():
                writer.write_eof()
        except OSError:
            pass


async def pipe_both(r1, w1, r2, w2):
    await asyncio.gather(pipe(r1, w2), pipe(r2, w1))
    for w in (w1, w2):
        try:
            w.close()
        except OSError:
            pass


async def watch_parent(stop):
    parent = os.getppid()
    while not stop.is_set():
        if os.getppid() != parent:
            stop.set()
            return
        await asyncio.sleep(0.25)


async def run_serve(a):
    log = Log(a.log, a.stage, a.id)
    proxy = Proxy(parse_hosts(a.hosts), log)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        loop.add_signal_handler(sig, stop.set)
    tmp = a.sock + '.tmp'
    if os.path.exists(tmp):
        os.unlink(tmp)
    server = await asyncio.start_unix_server(proxy.handle, path=tmp, limit=HEAD_MAX * 2)
    os.chmod(tmp, 0o666)
    os.rename(tmp, a.sock)  # the socket appears only when it is serving
    watcher = asyncio.ensure_future(watch_parent(stop))
    await stop.wait()
    watcher.cancel()
    server.close()
    log.write(f'END allow={proxy.allow} deny={proxy.deny}')
    try:
        os.unlink(a.sock)
    except OSError:
        pass


# --- the forwarder (inside the namespace, and `fwd`) ---------------------------

def forwarder(sock_path):
    active = 0
    async def handle(reader, writer):
        nonlocal active
        if active >= MAX_CONNECTIONS:
            writer.close()
            return
        active += 1
        try:
            ur, uw = await asyncio.wait_for(asyncio.open_unix_connection(sock_path), CONNECT_TIMEOUT_S)
            await pipe_both(reader, writer, ur, uw)
        except (OSError, asyncio.TimeoutError):
            writer.close()
        finally:
            active -= 1
    return handle


async def run_fwd(a):
    host, _, port = a.listen.rpartition(':')
    if not host or not port.isdigit():
        sys.exit(2)
    server = await asyncio.start_server(forwarder(a.sock), host.strip('[]'), int(port))
    port = server.sockets[0].getsockname()[1]
    tmp = a.port_file + '.tmp'
    with open(tmp, 'w') as f:
        f.write(f'{port}\n')
    os.rename(tmp, a.port_file)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    asyncio.ensure_future(watch_parent(stop))
    await stop.wait()
    server.close()


# --- inner: the namespace side ------------------------------------------------

SIOCGIFFLAGS, SIOCSIFFLAGS, IFF_UP = 0x8913, 0x8914, 0x1


def lo_up():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        ifr = struct.pack('16sh', b'lo', 0)
        flags = struct.unpack('16sh', fcntl_ioctl(s, SIOCGIFFLAGS, ifr))[1]
        fcntl_ioctl(s, SIOCSIFFLAGS, struct.pack('16sh', b'lo', flags | IFF_UP))
    finally:
        s.close()


def fcntl_ioctl(s, req, arg):
    import fcntl
    return fcntl.ioctl(s.fileno(), req, arg + b'\0' * (40 - len(arg)))[:len(arg)]


def anyip_route(family):
    """`ip route add local 0/0 dev lo table local`, as one rtnetlink message:
    every destination becomes local, so a direct connect lands on a catch
    listener instead of failing silently in the kernel."""
    RTM_NEWROUTE, NLM_F_REQUEST, NLM_F_ACK, NLM_F_CREATE, NLM_F_REPLACE = 24, 1, 4, 0x400, 0x100
    RT_TABLE_LOCAL, RTPROT_BOOT, RT_SCOPE_HOST, RTN_LOCAL, RTA_OIF, NLMSG_ERROR = 255, 3, 254, 2, 4, 2
    ifindex = socket.if_nametoindex('lo')
    rtmsg = struct.pack('BBBBBBBBI', family, 0, 0, 0, RT_TABLE_LOCAL, RTPROT_BOOT, RT_SCOPE_HOST, RTN_LOCAL, 0)
    attr = struct.pack('HHI', 8, RTA_OIF, ifindex)
    payload = rtmsg + attr
    hdr = struct.pack('IHHII', 16 + len(payload), RTM_NEWROUTE,
                      NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_REPLACE, 1, 0)
    s = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, 0)  # NETLINK_ROUTE
    try:
        s.settimeout(2)
        s.bind((0, 0))
        s.send(hdr + payload)
        resp = s.recv(4096)
    finally:
        s.close()
    mtype = struct.unpack('IHHII', resp[:16])[1]
    if mtype != NLMSG_ERROR or struct.unpack('i', resp[16:20])[0] != 0:
        raise OSError('route add refused')


def set_pdeathsig(sig=signal.SIGKILL):
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        libc.prctl(1, int(sig), 0, 0, 0)  # PR_SET_PDEATHSIG
    except (OSError, AttributeError):
        pass


async def run_inner(a, cmd):
    log = Log(a.log, a.stage, a.id)
    setpriv = shutil.which('setpriv')
    if not setpriv:
        log.write('ERR capability-drop-unavailable')
        return 127
    direct = 0
    try:
        lo_up()
    except OSError:
        pass
    direct_log = 'on'
    try:
        anyip_route(socket.AF_INET)
    except OSError:
        direct_log = 'off'
    try:
        anyip_route(socket.AF_INET6)
    except OSError:
        pass

    def catch(reader, writer):
        nonlocal direct
        direct += 1
        try:
            dst = writer.get_extra_info('sockname')
            log.deny('DENY-DIRECT', f'{dst[0]}:{dst[1]}', 'direct')
        finally:
            writer.close()

    servers = []
    servers.append(await asyncio.start_server(forwarder(a.sock), '127.0.0.1', PROXY_PORT))
    try:
        servers.append(await asyncio.start_server(forwarder(a.sock), '::1', PROXY_PORT))
    except OSError:
        pass
    for port in CATCH_PORTS:
        for host in ('0.0.0.0', '::'):
            try:
                servers.append(await asyncio.start_server(catch, host, port, reuse_address=True))
            except OSError:
                pass

    env = dict(os.environ)
    url = f'http://127.0.0.1:{PROXY_PORT}'
    for k in ('HTTPS_PROXY', 'HTTP_PROXY', 'https_proxy', 'http_proxy',
              'npm_config_https_proxy', 'npm_config_proxy'):
        env[k] = url
    env['NO_PROXY'] = env['no_proxy'] = 'localhost,127.0.0.1,::1'
    cmd = [setpriv, '--inh-caps=-sys_admin,-net_admin',
           '--bounding-set=-sys_admin,-net_admin', '--'] + cmd
    log.write(f'INNER direct_log={direct_log} caps=dropped')

    try:
        child = await asyncio.create_subprocess_exec(*cmd, env=env, preexec_fn=set_pdeathsig)
    except OSError as e:
        log.write(f'ERR exec-failed {safe(type(e).__name__, 40)}')
        return 127
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        loop.add_signal_handler(sig, lambda s=sig: child.returncode is None and child.send_signal(s))
    rc = await child.wait()
    for s in servers:
        s.close()
    log.write(f'END-INNER direct={direct}')
    return 128 - rc if rc < 0 else rc


# --- cli ----------------------------------------------------------------------

def main(argv):
    cmd = []
    if '--' in argv:
        i = argv.index('--')
        argv, cmd = argv[:i], argv[i + 1:]
    p = argparse.ArgumentParser(prog='egress-proxy.py')
    sub = p.add_subparsers(dest='mode', required=True)
    s = sub.add_parser('serve')
    for k in ('--sock', '--stage', '--log', '--id'):
        s.add_argument(k, required=True)
    s.add_argument('--hosts', default='')
    n = sub.add_parser('inner')
    for k in ('--sock', '--stage', '--log', '--id'):
        n.add_argument(k, required=True)
    f = sub.add_parser('fwd')
    for k in ('--listen', '--sock', '--port-file'):
        f.add_argument(k, required=True)
    m = sub.add_parser('match')
    m.add_argument('--hosts', default='')
    m.add_argument('target')
    a = p.parse_args(argv)

    if a.mode == 'match':
        hp = split_hostport(a.target, 443)
        return 0 if hp and allowed(hp[0], hp[1], parse_hosts(a.hosts)) else 1
    if a.mode == 'serve':
        asyncio.run(run_serve(a))
        return 0
    if a.mode == 'fwd':
        asyncio.run(run_fwd(a))
        return 0
    if not cmd:
        p.error('inner needs -- <cmd...>')
    set_pdeathsig()
    return asyncio.run(run_inner(a, cmd))


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
