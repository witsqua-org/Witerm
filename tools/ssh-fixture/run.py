#!/usr/bin/env python3
"""Run disposable OpenSSH acceptance fixtures without using user SSH material."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]


def main():
    directory = Path(tempfile.mkdtemp(prefix="witerm-ssh-test-"))
    directory.chmod(0o700)
    project = "witerm-ssh-test-" + uuid.uuid4().hex[:10]
    env = dict(os.environ, WITERM_SSH_FIXTURE_DIRECTORY=str(directory))
    compose = ["docker", "compose", "-p", project, "-f", str(ROOT / "tools/ssh-fixture/compose.yaml")]
    try:
        for name, password in [("client", ""), ("encrypted", "fixture-key-passphrase")]:
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", password,
                            "-f", str(directory / name)], check=True)
        for name in ["target", "jump"]:
            folder = directory / name
            folder.mkdir(mode=0o700)
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "",
                            "-f", str(folder / "host")], check=True)
            for public_key in ["client.pub", "encrypted.pub"]:
                shutil.copy2(directory / public_key, folder / public_key)
        subprocess.run(compose + ["config", "--quiet"], env=env, check=True)
        subprocess.run(compose + ["up", "--build", "-d", "--wait"], env=env, check=True)
        ports = {}
        for name in ["target", "jump"]:
            result = subprocess.check_output(compose + ["port", name, "22"], env=env, text=True)
            port = int(result.strip().rsplit(":", 1)[1])
            if not 0 < port < 65536:
                raise RuntimeError("Fixture localhost port was not assigned")
            ports[name] = port
        config = directory / "config.json"
        config.write_text(json.dumps({
            "targetPort": ports["target"], "jumpPort": ports["jump"],
            "privateKeyFile": str(directory / "client"),
            "encryptedKeyFile": str(directory / "encrypted"),
            "targetPublicKeyFile": str(directory / "target/host.pub"),
            "jumpPublicKeyFile": str(directory / "jump/host.pub"),
        }))
        config.chmod(0o600)
        subprocess.run(["swift", "test", "--package-path", str(ROOT / "packages/WitermSSH"),
                        "-j", "4", "--filter", "SSHLiveTests"],
                       env=dict(env, WITERM_SSH_INTEGRATION_CONFIG=str(config)), check=True)
    finally:
        subprocess.run(compose + ["down", "--remove-orphans"], env=env, check=False)
        shutil.rmtree(directory)


if __name__ == "__main__":
    main()
