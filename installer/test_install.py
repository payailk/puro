"""Exercise the real installer with local release assets and no network access."""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


INSTALLER = Path(__file__).with_name("install.sh")
ASSETS = ("puro-darwin-arm64", "puro-darwin-x64")


class InstallerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.commands = self.directory / "commands"
        self.commands.mkdir()
        self.root = self.directory / "puro root"
        (self.root / "bin").mkdir(parents=True)
        self.installed = self.root / "bin" / "puro"
        self.installed.write_text("existing installation")
        self.calls = self.directory / "install-call"
        self.version_calls = self.directory / "version-call"
        self.config_calls = self.directory / "config-call"
        self.urls = self.directory / "urls"
        self.env = dict(os.environ)
        for key in ("PURO_VERSION", "PURO_REPOSITORY", "PURO_RELEASES_URL", "PURO_FLUTTER_BIN"):
            self.env.pop(key, None)
        self.env.update(
            PATH=str(self.commands) + os.pathsep + self.env["PATH"],
            PURO_ROOT=str(self.root),
            TEST_DIRECTORY=str(self.directory),
            TEST_OS="Darwin",
            TEST_ARCH="arm64",
            TEST_CALL=str(self.calls),
            TEST_VERSION_CALL=str(self.version_calls),
            TEST_CONFIG_CALL=str(self.config_calls),
            TEST_URLS=str(self.urls),
        )
        self.command("uname", '#!/bin/bash\nif [ "$1" = -s ]; then echo "$TEST_OS"; else echo "$TEST_ARCH"; fi\n')
        self.command("curl", f"#!{sys.executable}\n" + '''
import json
import os
from pathlib import Path
import shutil
import sys
args = sys.argv[1:]
url = args[-1]
with open(os.environ["TEST_URLS"], "a") as log:
    log.write(url + "\\n")
if os.environ.get("TEST_DOWNLOAD_FAIL") == url.rsplit("/", 1)[-1]:
    sys.exit(22)
assert "-fL" in args
output = Path(args[args.index("--output") + 1])
if "/api/v5/repos/" in url:
    repository = os.environ.get("PURO_REPOSITORY", "robinzzz1/puro")
    requested = os.environ.get("PURO_VERSION", "latest")
    version = "1.5.0-ohos.4" if requested == "latest" else requested.removeprefix("v")
    tag = "v" + version
    asset_root = f"https://gitee.com/{repository}/releases/download/{tag}"
    output.write_text(json.dumps({
        "tag_name": tag,
        "prerelease": False,
        "assets": [
            {"name": asset, "browser_download_url": f"{asset_root}/{asset}"}
            for asset in ("puro-darwin-arm64", "puro-darwin-x64", "SHA256SUMS")
        ],
    }))
else:
    shutil.copyfile(Path(os.environ["TEST_DIRECTORY"]) / url.rsplit("/", 1)[-1], output)
''')
        self.command("plutil", f"#!{sys.executable}\n" + '''
import json
from pathlib import Path
import sys
args = sys.argv[1:]
value = json.loads(Path(args[-1]).read_text())
try:
    for component in args[args.index("-extract") + 1].split("."):
        value = value[int(component)] if isinstance(value, list) else value[component]
except (KeyError, IndexError, ValueError):
    sys.exit(1)
print(str(value).lower() if isinstance(value, bool) else value)
''')
        binary = '''#!/bin/bash
case "$*" in
  "--no-install --no-update-check version --plain")
    printf '%s\\n' "$@" > "$TEST_VERSION_CALL"
    printf '%s\\n' '1.5.0-ohos.4'
    ;;
  "install-puro --promote")
printf '%s\\n' "$@" "$PURO_ROOT" > "$TEST_CALL"
mv "$0" "$PURO_ROOT/bin/puro"
exit "${TEST_INSTALL_EXIT:-0}"
    ;;
  "--no-install --no-update-check --json config set puroBuildsUrl "*)
    printf '%s\\n' "$@" > "$TEST_CONFIG_CALL"
    ;;
  *) exit 2 ;;
esac
'''
        for asset in ASSETS:
            (self.directory / asset).write_text(binary)
        self.manifest = self.directory / "SHA256SUMS"
        self.manifest.write_text("".join(
            hashlib.sha256((self.directory / asset).read_bytes()).hexdigest()
            + "  " + asset + "\n" for asset in ASSETS
        ))

    def command(self, name, content):
        command = self.commands / name
        command.write_text(content)
        command.chmod(0o755)

    def run_installer(self, *, sourced=False):
        if sourced:
            args = ["bash", "-c", 'source "$1"', "bash", str(INSTALLER)]
            script = None
        else:
            # This is the same stdin execution used by curl ... | bash.
            args = ["bash"]
            script = INSTALLER.read_text()
        result = subprocess.run(args, input=script, env=self.env, capture_output=True, text=True)
        self.assertEqual(list((self.root / "bin").glob(".puro-install.*")), [])
        return result

    def assert_not_installed(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.calls.exists())
        self.assertEqual(self.installed.read_text(), "existing installation")

    def test_platforms_and_versions(self):
        for os_name, arch, asset, version, release_path in (
            ("Darwin", "arm64", "puro-darwin-arm64", "latest", "latest"),
            ("Darwin", "x86_64", "puro-darwin-x64", "1.5.0-ohos.4", "tags/v1.5.0-ohos.4"),
            ("Darwin", "arm64", "puro-darwin-arm64", "v1.5.0-ohos.4", "tags/v1.5.0-ohos.4"),
        ):
            with self.subTest(os=os_name, arch=arch, version=version):
                self.env.update(TEST_OS=os_name, TEST_ARCH=arch, PURO_VERSION=version)
                result = self.run_installer()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.calls.read_text().splitlines(), ["install-puro", "--promote", str(self.root)])
                self.assertEqual(
                    self.version_calls.read_text().splitlines(),
                    ["--no-install", "--no-update-check", "version", "--plain"],
                )
                self.assertEqual(self.urls.read_text().splitlines()[-3:], [
                    f"https://gitee.com/api/v5/repos/robinzzz1/puro/releases/{release_path}",
                    f"https://gitee.com/robinzzz1/puro/releases/download/v1.5.0-ohos.4/{asset}",
                    "https://gitee.com/robinzzz1/puro/releases/download/v1.5.0-ohos.4/SHA256SUMS",
                ])
                self.assertEqual(self.config_calls.read_text().splitlines(), [
                    "--no-install", "--no-update-check", "--json", "config", "set", "puroBuildsUrl",
                    "https://gitee.com/api/v5/repos/robinzzz1/puro/releases",
                ])

    def test_default_latest_and_custom_repository_when_sourced(self):
        self.env["PURO_REPOSITORY"] = "example/puro"
        result = self.run_installer(sourced=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.urls.read_text().splitlines(), [
            "https://gitee.com/api/v5/repos/example/puro/releases/latest",
            "https://gitee.com/example/puro/releases/download/v1.5.0-ohos.4/puro-darwin-arm64",
            "https://gitee.com/example/puro/releases/download/v1.5.0-ohos.4/SHA256SUMS",
        ])

    def test_unsupported_architecture(self):
        for arch in ("x86_64", "aarch64"):
            with self.subTest(arch=arch):
                self.env.update(TEST_OS="Linux", TEST_ARCH=arch)
                self.assert_not_installed(self.run_installer())
                self.assertFalse(self.urls.exists())

    def test_invalid_version(self):
        self.env["PURO_VERSION"] = "../../master"
        self.assert_not_installed(self.run_installer())
        self.assertFalse(self.urls.exists())

    def test_invalid_repository(self):
        self.env["PURO_REPOSITORY"] = "example/puro/../../other"
        self.assert_not_installed(self.run_installer())
        self.assertFalse(self.urls.exists())

    def test_default_root(self):
        self.env.pop("PURO_ROOT")
        self.env["HOME"] = str(self.directory)
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text().splitlines()[-1], str(self.directory / ".puro"))
        self.assertTrue((self.directory / ".puro/bin/puro").exists())

    @unittest.skipUnless(shutil.which("shasum"), "shasum is not installed")
    def test_shasum_fallback(self):
        for command in ("bash", "mkdir", "mktemp", "rm", "awk", "chmod", "shasum", "mv"):
            (self.commands / command).symlink_to(shutil.which(command))
        self.env["PATH"] = str(self.commands)
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.calls.exists())

    def test_download_failure(self):
        for asset in ("latest", "puro-darwin-arm64", "SHA256SUMS"):
            with self.subTest(asset=asset):
                self.env["TEST_DOWNLOAD_FAIL"] = asset
                self.assert_not_installed(self.run_installer())

    def test_corrupt_binary(self):
        (self.directory / "puro-darwin-arm64").write_text("corrupted download")
        self.assert_not_installed(self.run_installer())

    def test_missing_checksum(self):
        self.manifest.write_text("")
        self.assert_not_installed(self.run_installer())

    def test_install_exit_status(self):
        self.env["TEST_INSTALL_EXIT"] = "7"
        self.assertEqual(self.run_installer().returncode, 7)


if __name__ == "__main__":
    unittest.main()
