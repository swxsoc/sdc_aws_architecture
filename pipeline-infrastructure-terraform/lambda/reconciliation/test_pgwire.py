"""Unit tests for the TLS and credential handling of ``pgwire.connect``.

Run from this directory with ``python -m unittest``. A fake server on the
loopback interface plays the first steps of the PostgreSQL protocol; the
tests that need a certificate make a throwaway self-signed one with the
``openssl`` command and are skipped where that is unavailable.
"""

from __future__ import annotations

import shutil
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

import pgwire


class FakeServer:
    """Accept one connection, answer the SSLRequest and record what follows."""

    def __init__(self, answer: bytes, context: ssl.SSLContext | None = None):
        self.answer = answer
        self.context = context
        self.ssl_request = b""
        self.startup: bytes | None = None
        self.after_refusal: bytes | None = None
        self._listener = socket.create_server(("127.0.0.1", 0))
        self._listener.settimeout(5)
        self.port = self._listener.getsockname()[1]
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self) -> None:
        try:
            connection, _ = self._listener.accept()
        except OSError:
            return
        with connection:
            connection.settimeout(5)
            try:
                self.ssl_request = connection.recv(8)
                connection.sendall(self.answer)
                if self.context is None:
                    # Anything a client sends now would travel in the clear.
                    self.after_refusal = connection.recv(4096)
                    return
                with self.context.wrap_socket(connection, server_side=True) as tls:
                    (length,) = struct.unpack("!I", tls.recv(4))
                    self.startup = tls.recv(length - 4)
                    tls.sendall(b"R" + struct.pack("!II", 8, pgwire.AUTH_OK))
                    tls.sendall(b"Z" + struct.pack("!I", 5) + b"I")
                    tls.recv(4096)
            except OSError:
                # A client that rejects the certificate drops the handshake.
                return

    def close(self) -> None:
        self._thread.join(timeout=5)
        self._listener.close()


def connect(server: FakeServer, host: str, **kwargs) -> pgwire.Connection:
    return pgwire.connect(
        host, server.port, "metatracker", "tester", "not-a-real-password", **kwargs
    )


class DefaultTrust(unittest.TestCase):
    def test_default_context_verifies_against_the_rds_roots_only(self):
        context = pgwire.tls_context()
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(context.check_hostname)
        self.assertGreaterEqual(context.minimum_version, ssl.TLSVersion.TLSv1_2)
        roots = context.get_ca_certs()
        self.assertGreaterEqual(len(roots), 3)
        for root in roots:
            subject = dict(pair for group in root["subject"] for pair in group)
            self.assertEqual(subject["organizationalUnitName"], "Amazon RDS")
            self.assertEqual(root["subject"], root["issuer"])
        regions = {
            dict(pair for group in root["subject"] for pair in group)["commonName"]
            for root in roots
        }
        self.assertIn("Amazon RDS us-east-1 Root CA RSA2048 G1", regions)

    def test_a_context_that_does_not_verify_is_refused(self):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        with self.assertRaisesRegex(pgwire.PostgresError, "must verify"):
            pgwire.connect("127.0.0.1", 1, "db", "user", "pw", ssl_context=context)


class TlsIsMandatory(unittest.TestCase):
    def test_a_server_that_refuses_tls_is_sent_nothing(self):
        server = FakeServer(b"N")
        with self.assertRaisesRegex(pgwire.PostgresError, "refused TLS"):
            connect(server, "127.0.0.1")
        server.close()
        self.assertEqual(
            server.ssl_request, struct.pack("!II", 8, pgwire.SSL_REQUEST_CODE)
        )
        self.assertEqual(server.after_refusal, b"")


@unittest.skipUnless(shutil.which("openssl"), "needs the openssl command")
class CertificateVerification(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._directory = tempfile.TemporaryDirectory()
        directory = Path(cls._directory.name)
        cls.certificate = directory / "server.pem"
        key = directory / "server.key"
        made = subprocess.run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-days",
                "2",
                "-subj",
                "/CN=localhost",
                "-addext",
                "subjectAltName=DNS:localhost",
                "-keyout",
                str(key),
                "-out",
                str(cls.certificate),
            ],
            capture_output=True,
            check=False,
        )
        if made.returncode != 0:
            cls._directory.cleanup()
            raise unittest.SkipTest("openssl could not make a test certificate")
        cls.server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        cls.server_context.load_cert_chain(cls.certificate, key)

    @classmethod
    def tearDownClass(cls):
        cls._directory.cleanup()

    def test_a_certificate_outside_the_rds_roots_is_sent_nothing(self):
        server = FakeServer(b"S", self.server_context)
        with self.assertRaisesRegex(pgwire.PostgresError, "TLS verification"):
            connect(server, "localhost")
        server.close()
        self.assertIsNone(server.startup)

    def test_a_trusted_certificate_for_another_host_is_sent_nothing(self):
        server = FakeServer(b"S", self.server_context)
        with self.assertRaisesRegex(pgwire.PostgresError, "TLS verification"):
            connect(
                server,
                "127.0.0.1",
                ssl_context=pgwire.tls_context(self.certificate),
            )
        server.close()
        self.assertIsNone(server.startup)

    def test_a_trusted_certificate_for_this_host_connects(self):
        server = FakeServer(b"S", self.server_context)
        connection = connect(
            server, "localhost", ssl_context=pgwire.tls_context(self.certificate)
        )
        connection.close()
        server.close()
        self.assertIsNotNone(server.startup)
        self.assertIn(b"user\x00tester\x00", server.startup)


if __name__ == "__main__":
    unittest.main()
