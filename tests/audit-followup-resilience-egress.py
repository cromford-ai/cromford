"""Small, in-memory proxy regressions; no external connections or privileges."""
import asyncio
import importlib.util
import pathlib
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("fixture_proxy", pathlib.Path(__file__).parents[1] / "bin/egress-proxy.py")
proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy)


class Writer:
    def __init__(self):
        self.data = bytearray()
    def write(self, data): self.data.extend(data)
    async def drain(self): pass
    def close(self): pass


class ProxyTests(unittest.IsolatedAsyncioTestCase):
    async def request(self, headers, body=b"", target="http://fixture.example/path"):
        log = types.SimpleNamespace(stage="fixture", write=lambda _: None, deny=lambda *_: None)
        p = proxy.Proxy(proxy.parse_hosts("fixture.example"), log)
        reader = asyncio.StreamReader()
        reader.feed_data((f"POST {target} HTTP/1.1\r\n{headers}\r\n\r\n").encode() + body)
        reader.feed_eof()
        upstream = Writer()
        calls = []
        async def connect(host, port):
            calls.append((host, port))
            r = asyncio.StreamReader()
            r.feed_data(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
            r.feed_eof()
            return r, upstream
        p.upstream = connect
        writer = Writer()
        await p.handle(reader, writer)
        return bytes(writer.data), bytes(upstream.data), calls

    async def test_duplicate_content_length_is_rejected_before_connect(self):
        data, _, calls = await self.request("Host: fixture.example\r\nContent-Length: 1\r\nContent-Length: 1", b"x")
        self.assertIn(b"400 Bad Request", data)
        self.assertEqual(calls, [])

    async def test_duplicate_host_is_rejected(self):
        data, _, calls = await self.request("Host: fixture.example\r\nHost: other.example")
        self.assertIn(b"400 Bad Request", data)
        self.assertEqual(calls, [])

    async def test_host_cannot_change_the_authorized_http_destination(self):
        data, _, calls = await self.request("Host: other.example")
        self.assertIn(b"400 Bad Request", data)
        self.assertEqual(calls, [])

    async def test_authority_is_canonicalized_and_allowed_request_survives(self):
        data, forwarded, calls = await self.request("Host: Fixture.Example.:80\r\nContent-Length: 1", b"x")
        self.assertIn(b"200 OK", data)
        self.assertIn(b"Host: fixture.example\r\n", forwarded)
        self.assertEqual(calls, [("fixture.example", 80)])

    async def test_body_limit_is_checked_before_reading_or_connecting(self):
        data, _, calls = await self.request("Host: fixture.example\r\nContent-Length: 1048577")
        self.assertIn(b"413 Content Too Large", data)
        self.assertEqual(calls, [])

    async def test_incomplete_headers_have_a_deadline(self):
        log = types.SimpleNamespace(stage="fixture", write=lambda _: None, deny=lambda *_: None)
        p = proxy.Proxy([], log)
        reader, writer = asyncio.StreamReader(), Writer()
        reader.feed_data(b"GET ")
        with patch.object(proxy, "READ_TIMEOUT_S", 0.01, create=True):
            await asyncio.wait_for(p.handle(reader, writer), 0.5)
        self.assertIn(b"408 Request Timeout", writer.data)

    async def test_connection_bound_does_not_queue_an_extra_reader(self):
        log = types.SimpleNamespace(stage="fixture", write=lambda _: None, deny=lambda *_: None)
        p = proxy.Proxy([], log)
        p.active = 1
        with patch.object(proxy, "MAX_CONNECTIONS", 1, create=True):
            reader, writer = asyncio.StreamReader(), Writer()
            await asyncio.wait_for(p.handle(reader, writer), 0.5)
        self.assertIn(b"503 Service Unavailable", writer.data)

    async def test_inner_never_launches_without_capability_drop(self):
        a = types.SimpleNamespace(log="/scratch/fixture-egress.log", stage="fixture", id="fixture", sock="/scratch/absent-fixture-socket")
        with patch.object(proxy.shutil, "which", return_value=None), patch.object(proxy, "lo_up") as lo:
            rc = await proxy.run_inner(a, ["fixture-never-run"])
        self.assertEqual(rc, 127)
        lo.assert_not_called()


if __name__ == "__main__":
    unittest.main()
