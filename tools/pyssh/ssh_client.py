#!/usr/bin/env python3
import argparse
import sys
import time
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
VENDOR_DIR = SCRIPT_DIR / "vendor"
if VENDOR_DIR.exists():
    sys.path.insert(0, str(VENDOR_DIR))

import paramiko  # type: ignore


def build_client(host: str, port: int, user: str, password: str, timeout: int) -> paramiko.SSHClient:
    connect_timeout = max(5, min(int(timeout), 60)) if timeout > 0 else 30
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        hostname=host,
        port=port,
        username=user,
        password=password,
        timeout=connect_timeout,
        banner_timeout=connect_timeout,
        auth_timeout=connect_timeout,
        look_for_keys=False,
        allow_agent=False,
    )
    return client


def run_exec(args: argparse.Namespace) -> int:
    client = build_client(args.host, args.port, args.user, args.password, args.timeout)
    try:
        transport = client.get_transport()
        if transport is None:
            sys.stderr.write("SSH transport could not be created.\n")
            return 2

        channel = transport.open_session()
        channel.exec_command(args.command)

        deadline = None
        if int(args.timeout) > 0:
            deadline = time.monotonic() + int(args.timeout)

        stdout_chunks = []
        stderr_chunks = []

        while True:
            while channel.recv_ready():
                chunk = channel.recv(65536)
                stdout_chunks.append(chunk)
                sys.stdout.write(chunk.decode("utf-8", errors="replace"))
                sys.stdout.flush()
            while channel.recv_stderr_ready():
                chunk = channel.recv_stderr(65536)
                stderr_chunks.append(chunk)
                sys.stderr.write(chunk.decode("utf-8", errors="replace"))
                sys.stderr.flush()

            if channel.exit_status_ready():
                break

            if deadline is not None and time.monotonic() >= deadline:
                channel.close()
                sys.stderr.write(f"SSH command timed out after {args.timeout} second(s).\n")
                return 124

            time.sleep(0.2)

        while channel.recv_ready():
            chunk = channel.recv(65536)
            stdout_chunks.append(chunk)
            sys.stdout.write(chunk.decode("utf-8", errors="replace"))
            sys.stdout.flush()
        while channel.recv_stderr_ready():
            chunk = channel.recv_stderr(65536)
            stderr_chunks.append(chunk)
            sys.stderr.write(chunk.decode("utf-8", errors="replace"))
            sys.stderr.flush()

        out = b"".join(stdout_chunks).decode("utf-8", errors="replace")
        err = b"".join(stderr_chunks).decode("utf-8", errors="replace")
        exit_code = channel.recv_exit_status()
        return int(exit_code)
    finally:
        client.close()


def run_copy(args: argparse.Namespace) -> int:
    local_path = Path(args.local).expanduser().resolve()
    if not local_path.exists():
        sys.stderr.write(f"Local file was not found: {local_path}\n")
        return 2

    client = build_client(args.host, args.port, args.user, args.password, args.timeout)
    try:
        sftp = client.open_sftp()
        try:
            sftp.put(str(local_path), args.remote)
        finally:
            sftp.close()
        return 0
    finally:
        client.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Portable SSH/SFTP client wrapper based on Paramiko.")
    subparsers = parser.add_subparsers(dest="action", required=True)

    def add_common(common_parser: argparse.ArgumentParser) -> None:
        common_parser.add_argument("--host", required=True, help="Remote host or FQDN")
        common_parser.add_argument("--port", type=int, default=22, help="Remote SSH port")
        common_parser.add_argument("--user", required=True, help="SSH username")
        common_parser.add_argument("--password", required=True, help="SSH password")
        common_parser.add_argument("--timeout", type=int, default=30, help="Connection timeout in seconds")

    exec_parser = subparsers.add_parser("exec", help="Execute a remote command over SSH")
    add_common(exec_parser)
    exec_parser.add_argument("--command", required=True, help="Remote command to execute")

    copy_parser = subparsers.add_parser("copy", help="Copy local file to remote path over SFTP")
    add_common(copy_parser)
    copy_parser.add_argument("--local", required=True, help="Local file path")
    copy_parser.add_argument("--remote", required=True, help="Remote file path")

    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.action == "exec":
        return run_exec(args)
    if args.action == "copy":
        return run_copy(args)
    sys.stderr.write(f"Unsupported action: {args.action}\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
