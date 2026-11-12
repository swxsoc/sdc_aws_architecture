"""A minimal PostgreSQL client for read-only queries from a Lambda.

The managed Python runtime ships no PostgreSQL driver and this repository does
not vendor one, so the reconciliation Lambda speaks the frontend/backend
protocol (version 3.0) directly. It supports exactly what the reconciliation
needs: a mandatory, verified TLS connection, MD5 and SCRAM-SHA-256 password
authentication, simple-query execution and text-format result rows.
Everything else in the protocol is out of scope.

The server is authenticated before any credential is sent. Amazon RDS
certificates chain to Amazon's own RDS roots, which are in no public trust
store, so the roots are packaged next to this module as
``rds-global-bundle.pem``. That file is an unmodified copy of
https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem (every
region's RSA2048, RSA4096 and ECC384 roots; the earliest expires in 2061).
Replace it with a fresh download if AWS adds a region or a root.

Only ``connect`` and ``Connection.query`` are public. Values are interpolated
by the caller through ``quote_literal`` and ``quote_identifier``; there is no
parameter binding in the simple-query protocol.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import socket
import ssl
import struct
from pathlib import Path
from typing import Self

PROTOCOL_VERSION = 196608  # 3.0
SSL_REQUEST_CODE = 80877103

AUTH_OK = 0
AUTH_CLEARTEXT = 3
AUTH_MD5 = 5
AUTH_SASL = 10
AUTH_SASL_CONTINUE = 11
AUTH_SASL_FINAL = 12

RDS_CA_BUNDLE = Path(__file__).with_name("rds-global-bundle.pem")


class PostgresError(Exception):
    """Raised for protocol errors and for errors the server reports."""

    def __init__(self, message: str, fields: dict[str, str] | None = None):
        super().__init__(message)
        self.fields = fields or {}


def quote_literal(value: str) -> str:
    """Return ``value`` as a standard SQL string literal."""
    return "'" + value.replace("'", "''") + "'"


def quote_identifier(name: str) -> str:
    """Return ``name`` as a quoted SQL identifier."""
    return '"' + name.replace('"', '""') + '"'


def _message(kind: bytes, payload: bytes) -> bytes:
    return kind + struct.pack("!I", len(payload) + 4) + payload


def _cstring(value: str) -> bytes:
    return value.encode() + b"\x00"


class Connection:
    """One authenticated session. Use :func:`connect` to create it."""

    def __init__(self, sock: ssl.SSLSocket):
        self._sock = sock
        self._buffer = b""

    # -- wire helpers -------------------------------------------------------

    def _read_exact(self, size: int) -> bytes:
        while len(self._buffer) < size:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise PostgresError("connection closed by server")
            self._buffer += chunk
        data, self._buffer = self._buffer[:size], self._buffer[size:]
        return data

    def _read_message(self) -> tuple[bytes, bytes]:
        header = self._read_exact(5)
        kind = header[:1]
        (length,) = struct.unpack("!I", header[1:])
        return kind, self._read_exact(length - 4)

    def _send(self, data: bytes) -> None:
        self._sock.sendall(data)

    @staticmethod
    def _parse_error(payload: bytes) -> PostgresError:
        fields: dict[str, str] = {}
        for part in payload.split(b"\x00"):
            if part:
                fields[chr(part[0])] = part[1:].decode(errors="replace")
        return PostgresError(
            f"{fields.get('S', 'ERROR')} {fields.get('C', '')}: "
            f"{fields.get('M', 'unknown error')}",
            fields,
        )

    # -- authentication -----------------------------------------------------

    def _authenticate(self, user: str, password: str) -> None:
        scram: _Scram | None = None
        while True:
            kind, payload = self._read_message()
            if kind == b"E":
                raise self._parse_error(payload)
            if kind != b"R":
                raise PostgresError(f"unexpected message {kind!r} during auth")
            (code,) = struct.unpack("!I", payload[:4])
            body = payload[4:]
            if code == AUTH_OK:
                return
            if code == AUTH_CLEARTEXT:
                self._send(_message(b"p", _cstring(password)))
            elif code == AUTH_MD5:
                inner = hashlib.md5((password + user).encode()).hexdigest()
                digest = hashlib.md5(inner.encode() + body[:4]).hexdigest()
                self._send(_message(b"p", _cstring("md5" + digest)))
            elif code == AUTH_SASL:
                mechanisms = [m.decode() for m in body.split(b"\x00") if m]
                if "SCRAM-SHA-256" not in mechanisms:
                    raise PostgresError(f"unsupported SASL mechanisms {mechanisms}")
                scram = _Scram(password)
                first = scram.client_first()
                self._send(
                    _message(
                        b"p",
                        _cstring("SCRAM-SHA-256")
                        + struct.pack("!I", len(first))
                        + first,
                    )
                )
            elif code == AUTH_SASL_CONTINUE:
                if scram is None:
                    raise PostgresError("SASL continue before SASL start")
                self._send(_message(b"p", scram.client_final(body)))
            elif code == AUTH_SASL_FINAL:
                if scram is None:
                    raise PostgresError("SASL final before SASL start")
                scram.verify_server_final(body)
            else:
                raise PostgresError(f"unsupported authentication method {code}")

    def _wait_ready(self) -> None:
        while True:
            kind, payload = self._read_message()
            if kind == b"Z":
                return
            if kind == b"E":
                raise self._parse_error(payload)
            # ParameterStatus, BackendKeyData, NoticeResponse: nothing to do.

    # -- public API ---------------------------------------------------------

    def query(self, sql: str) -> list[tuple[str | None, ...]]:
        """Run one simple query and return its rows as text values.

        NULL is returned as ``None``. A statement with no result set returns an
        empty list. The server's error, if any, is raised as
        :class:`PostgresError` after the connection is back in a ready state.
        """
        self._send(_message(b"Q", _cstring(sql)))
        rows: list[tuple[str | None, ...]] = []
        error: PostgresError | None = None
        while True:
            kind, payload = self._read_message()
            if kind == b"D":
                (count,) = struct.unpack("!H", payload[:2])
                offset = 2
                values: list[str | None] = []
                for _ in range(count):
                    (length,) = struct.unpack("!i", payload[offset : offset + 4])
                    offset += 4
                    if length == -1:
                        values.append(None)
                    else:
                        values.append(payload[offset : offset + length].decode())
                        offset += length
                rows.append(tuple(values))
            elif kind == b"E":
                error = self._parse_error(payload)
            elif kind == b"Z":
                break
            # RowDescription, CommandComplete, EmptyQueryResponse, Notice: skip.
        if error is not None:
            raise error
        return rows

    def close(self) -> None:
        try:
            self._send(_message(b"X", b""))
        except OSError:
            pass
        finally:
            self._sock.close()

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()


class _Scram:
    """Client side of SCRAM-SHA-256 (RFC 7677) without channel binding."""

    def __init__(self, password: str):
        self._password = password.encode()
        self._nonce = base64.b64encode(os.urandom(24)).decode()
        self._client_first_bare = f"n=,r={self._nonce}".encode()
        self._auth_message = b""
        self._server_signature = b""

    def client_first(self) -> bytes:
        return b"n,," + self._client_first_bare

    def client_final(self, server_first: bytes) -> bytes:
        attributes = dict(
            part.split("=", 1) for part in server_first.decode().split(",")
        )
        nonce = attributes["r"]
        if not nonce.startswith(self._nonce):
            raise PostgresError("SCRAM server nonce does not extend client nonce")
        salt = base64.b64decode(attributes["s"])
        iterations = int(attributes["i"])
        salted = hashlib.pbkdf2_hmac("sha256", self._password, salt, iterations)
        client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
        stored_key = hashlib.sha256(client_key).digest()
        without_proof = f"c=biws,r={nonce}".encode()
        self._auth_message = b",".join(
            [self._client_first_bare, server_first, without_proof]
        )
        client_signature = hmac.new(
            stored_key, self._auth_message, hashlib.sha256
        ).digest()
        proof = bytes(a ^ b for a, b in zip(client_key, client_signature))
        server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
        self._server_signature = hmac.new(
            server_key, self._auth_message, hashlib.sha256
        ).digest()
        return without_proof + b",p=" + base64.b64encode(proof)

    def verify_server_final(self, server_final: bytes) -> None:
        attributes = dict(
            part.split("=", 1) for part in server_final.decode().split(",")
        )
        if "e" in attributes:
            raise PostgresError(f"SCRAM authentication failed: {attributes['e']}")
        expected = base64.b64encode(self._server_signature).decode()
        if not hmac.compare_digest(attributes.get("v", ""), expected):
            raise PostgresError("SCRAM server signature mismatch")


def tls_context(cafile: str | os.PathLike[str] | None = None) -> ssl.SSLContext:
    """Return a client context that trusts only ``cafile``.

    The default is the packaged Amazon RDS root bundle. The context requires
    a certificate that chains to one of those roots and matches the host
    name, over TLS 1.2 or later.
    """
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.verify_mode = ssl.CERT_REQUIRED
    context.check_hostname = True
    context.load_verify_locations(cafile=os.fspath(cafile or RDS_CA_BUNDLE))
    return context


def connect(
    host: str,
    port: int,
    database: str,
    user: str,
    password: str,
    timeout: float = 15.0,
    ssl_context: ssl.SSLContext | None = None,
) -> Connection:
    """Open and authenticate a connection over verified TLS.

    TLS is mandatory (the equivalent of ``sslmode=verify-full``): a server
    that refuses it, presents a certificate that does not chain to the
    trusted roots, or presents one for another host name is rejected before
    the startup message, so no user name or password reaches it.
    ``ssl_context`` replaces the default :func:`tls_context`; it must verify
    the certificate and the host name.
    """
    context = ssl_context or tls_context()
    if context.verify_mode != ssl.CERT_REQUIRED or not context.check_hostname:
        raise PostgresError("ssl_context must verify the certificate and host name")
    sock = socket.create_connection((host, port), timeout=timeout)
    try:
        sock.sendall(struct.pack("!II", 8, SSL_REQUEST_CODE))
        # Exactly one byte: nothing the peer sends before the handshake is
        # ever read as protocol data.
        answer = sock.recv(1)
        if answer == b"N":
            raise PostgresError("server refused TLS; refusing to send credentials")
        if answer != b"S":
            raise PostgresError(f"unexpected SSLRequest answer {answer!r}")
        try:
            sock = context.wrap_socket(sock, server_hostname=host)
        except ssl.SSLError as error:
            raise PostgresError(
                f"TLS verification of {host} failed: {error}"
            ) from error

        params = b"".join(
            _cstring(key) + _cstring(value)
            for key, value in (
                ("user", user),
                ("database", database),
                ("client_encoding", "UTF8"),
                ("application_name", "pipeline-reconciliation"),
            )
        )
        sock.sendall(
            struct.pack("!II", len(params) + 9, PROTOCOL_VERSION) + params + b"\x00"
        )
        connection = Connection(sock)
        connection._authenticate(user, password)
        connection._wait_ready()
        return connection
    except BaseException:
        sock.close()
        raise
