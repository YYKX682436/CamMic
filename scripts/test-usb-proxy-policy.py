#!/usr/bin/env python3
"""Simulated CLI-policy tests. These never claim physical USB verification."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class USBProxyPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cammic-proxy-policy-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.arguments = self.root / "arguments.txt"
        self.proxy = self.root / "iproxy"
        self.proxy.write_text(
            '#!/bin/bash\n'
            'if [[ "$1" == "--help" ]]; then printf "%s\\n" "$CAMMIC_TEST_PROXY_HELP"; exit 0; fi\n'
            'printf "%s\\n" "$@" > "$CAMMIC_TEST_PROXY_ARGS"\n'
        )
        self.proxy.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(self.root),
                                CAMMIC_TEST_PROXY_ARGS=str(self.arguments),
                                CAMMIC_TEST_PROXY_HELP="LOCAL_PORT:DEVICE_PORT --local --source ADDR --udid UDID")
        self.script = Path(__file__).resolve().with_name("run-iproxy-usb.sh")

    def run_proxy(self, *arguments):
        return subprocess.run(["/bin/bash", str(self.script), *arguments], env=self.environment,
                              text=True, capture_output=True, timeout=3)

    def test_explicit_usb_device_and_ipv4_loopback_only(self):
        result = self.run_proxy("fixture-device")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.arguments.read_text().splitlines(),
                         ["--local", "--udid", "fixture-device", "--source", "127.0.0.1",
                          "50888:50888", "50889:50889", "50890:50890"])

    def test_unverified_legacy_or_missing_bind_controls_fail_closed(self):
        for help_text in ("LOCAL_TCP_PORT DEVICE_TCP_PORT", "LOCAL_PORT:DEVICE_PORT --local",
                          "LOCAL_PORT:DEVICE_PORT --source ADDR"):
            with self.subTest(help_text=help_text):
                self.environment["CAMMIC_TEST_PROXY_HELP"] = help_text
                self.assertEqual(self.run_proxy("fixture-device").returncode, 2)
                self.assertFalse(self.arguments.exists())

    def test_device_must_be_explicit_and_missing_tool_is_rejected(self):
        for arguments in ((), ("",), ("device-a", "device-b")):
            self.assertEqual(self.run_proxy(*arguments).returncode, 2)
        self.proxy.unlink()
        self.assertEqual(self.run_proxy("fixture-device").returncode, 127)


if __name__ == "__main__":
    unittest.main()
