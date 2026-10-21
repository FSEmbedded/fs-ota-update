#! /usr/bin/env python3

# Copyright 2026 F&S Elektronik Systeme GmbH
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the “Software”), to deal in
# the Software without restriction, including without limitation the rights to use,
# copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
# Software, and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
# DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.

import argparse
import os
import sys
from pathlib import Path
import subprocess
import socket
import re
import shlex

API_SERVER_PORT = 8090
UI_SERVER_PORT = 8098

BASE_URL_API = f"http://localhost:{API_SERVER_PORT}"
BASE_URL_UI = f"http://localhost:{UI_SERVER_PORT}"

SCRIPT_DIR = Path(__file__).parent.resolve()
DOCKERFILE = SCRIPT_DIR / "hawkbit" / "docker-compose.yml"
HAWKBIT_SCRIPT = SCRIPT_DIR / "hawkbit" / "hawkbit.sh"

HAWKBIT_AUTH_TOKEN = "CHANGEME_TARGET_SECURITY_TOKEN"

def run_local_ssh(host, command):
    ssh_cmd = ['ssh', host, command]
    # Run command and capture output
    result = subprocess.run(ssh_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"Error running SSH command: {result.stderr}")
    return result.stdout, result.stderr, result.returncode


def set_remote_config_value(host, remote_path, key, value):
    if any("\n" in part or "\r" in part for part in (key, value)):
        raise ValueError("key and value must not contain newlines")

    pattern = rf"^([[:space:]]*{re.escape(key)}[[:space:]]*=[[:space:]]*).*"
    escaped_value = value.replace("\\", "\\\\").replace("&", "\\&").replace("|", "\\|")
    expression = f"s|{pattern}|\\1{escaped_value}|"
    command = f"sed -i -E {shlex.quote(expression)} {shlex.quote(str(remote_path))}"
    print(f"Setting remote config value: {key} = {value} at {remote_path}")
    run_local_ssh(host, command)


def upload_file_via_scp(host, user, local_file, remote_path):
    # Construct standard target target 'user@host:/path/to/dest'
    destination = f"{user}@{host}:{remote_path}"

    # Run the native scp command
    result = subprocess.run(["scp", local_file, destination],
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE,
                                text=True,
                                check=True)
    if result.returncode != 0:
        raise RuntimeError(f"Error running SCP command: {result.stderr}")


def getTargetName(machine):
    return f"{machine}-test"

def setConfigValue(path, key, value):
    path = Path(path)
    line = f"{key} = \"{value}\"\n"
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True) if path.exists() else []

    for index, existing_line in enumerate(lines):
        if existing_line.startswith(f"{key} ="):
            lines[index] = line
            break
    else:
        lines.append(line)
    print(f"Setting config value: {key} = \"{value}\"")
    path.write_text("".join(lines), encoding="utf-8")


class fsOtaUpdater:
    def __init__(self,commandRunner=subprocess.run, scriptDir=SCRIPT_DIR):

        self.commandRunner = commandRunner
        self.scriptDir = Path(scriptDir)

    def hawkbit(self, action):
        if action not in ("up", "down"):
            raise ValueError("action must be up or down")
        command = ["docker", "compose", "-f", str(self.scriptDir / "hawkbit" / "docker-compose.yml"), action]
        if action == "up":
            print("Starting Hawkbit via Docker Compose...")
            command.append("-d")
        else:
            print("Stopping Hawkbit via Docker Compose...")
        self.commandRunner(command, check=True)

    def generateCertificates(self, organisation, days):
        environment = os.environ.copy()
        environment.update({"ORG": organisation, "DAYS": days})
        self.commandRunner(
            ["bash", str(self.scriptDir / "fus-update-gen-certs.sh"), "--dir",
             str(self.scriptDir / "certs" / organisation)],
            check=True,
            env=environment,
        )

    def availableCerts(self):
        certs_dir = self.scriptDir / "certs"
        if not certs_dir.exists():
            return []
        return "\n".join(d.name for d in certs_dir.iterdir() if d.is_dir())

    def configureBuild(self, certs, machine, image, serverip, localconf):
        print(f"Using local config file: {localconf}")
        certpath = Path("certs") / certs
        certpath_docker = str(Path("/home/developer/fs-ota-update/") / certpath)
        target = getTargetName(machine)

        setConfigValue(localconf, "FUS_UPDATE_CERT_DIR", certpath_docker)
        setConfigValue(localconf, "FUS_BUNDLE_ROOTFS_IMAGE", image)
        setConfigValue(localconf, "FUS_UPDATE_HAWKBIT_SERVER", f"{serverip}:{API_SERVER_PORT}")
        setConfigValue(localconf, "FUS_UPDATE_HAWKBIT_SSL", "false")
        setConfigValue(localconf, "FUS_UPDATE_HAWKBIT_TENANT", "DEFAULT")
        setConfigValue(localconf, "FUS_UPDATE_HAWKBIT_TARGET", target)
        setConfigValue(localconf, "FUS_UPDATE_HAWKBIT_TOKEN", HAWKBIT_AUTH_TOKEN)
        setConfigValue(localconf, "MACHINE", machine)

    def configureBoard(self, certs, boardIP, serverip ,machine):
        print(f"Configuring board {boardIP}")

        run_local_ssh(f"root@{boardIP}", "mkdir -p /etc/rauc")
        run_local_ssh(f"root@{boardIP}", "cp -f /usr/lib/rauc/system.conf /etc/rauc/system.conf")
        set_remote_config_value(f"root@{boardIP}", "/etc/rauc/system.conf", "path", "/etc/rauc/ca.cert.pem")
        certs_dir = self.scriptDir / "certs"
        local_cert = certs_dir / certs / "dev" / "ca.cert.pem"
        print(f"Uploading local certificate {local_cert}")
        upload_file_via_scp(boardIP, "root", str(local_cert), "/etc/rauc/ca.cert.pem")
        run_local_ssh(f"root@{boardIP}", "systemctl restart rauc")

        conf = "/etc/rauc-hawkbit-updater/config.conf"
        print(f"Editing board {boardIP} config {conf}")
        set_remote_config_value(f"root@{boardIP}", conf, "hawkbit_server", f"{serverip}:{API_SERVER_PORT}")
        set_remote_config_value(f"root@{boardIP}", conf, "target_name", getTargetName(machine))
        set_remote_config_value(f"root@{boardIP}", conf, "auth_token", HAWKBIT_AUTH_TOKEN)
        run_local_ssh(f"root@{boardIP}", "systemctl restart rauc-hawkbit-updater")

        print(f"Done")


    def uploadRaucUpdateBundle(self, machine, bundle, ip):
        target = getTargetName(machine)
        hb_url=f"http://{ip}:{API_SERVER_PORT}"
        if not os.path.isfile(bundle):
            raise FileNotFoundError(f"RAUC update bundle not found: {bundle}")
        environment = os.environ.copy()
        environment["HB_URL"] = hb_url
        script = str(self.scriptDir / "hawkbit" / "hawkbit.sh")
        self.commandRunner(["bash", script, "wait", "5"], check=True, env=environment)
        self.commandRunner(["bash", script, "target", target, HAWKBIT_AUTH_TOKEN], check=True, env=environment)
        self.commandRunner(["bash", script, "deploy", bundle, target], check=True, env=environment)
        self.commandRunner(["bash", script, "verify", target], check=True, env=environment)

    def getLocalIp(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("8.8.8.8", 80))
            return sock.getsockname()[0]


def parseNamedArguments(parser, option, arguments, requiredKeys, optionalKeys=()):
    parsedArguments = {}
    allowedKeys = set(requiredKeys) | set(optionalKeys)

    for argument in arguments:
        if "=" not in argument:
            parser.error(f"{option} arguments must use key=value")
        key, value = argument.split("=", 1)
        if key not in allowedKeys:
            parser.error(f"{option} does not support {key}=...")
        if key in parsedArguments:
            parser.error(f"{option} received {key}=... more than once")
        parsedArguments[key] = value

    missingKeys = set(requiredKeys) - set(parsedArguments)
    if missingKeys:
        requirements = " and ".join(f"{key}=..." for key in requiredKeys)
        parser.error(f"{option} requires {requirements}")
    return parsedArguments


if __name__ == "__main__":

    updater = fsOtaUpdater()

    parser = argparse.ArgumentParser(description="F&S OTA Update Manager")

    parser.add_argument("--hawkbit", nargs=1, metavar="action=...",
                        help="Control Hawkbit, for example action=up")
    parser.add_argument("--generateCertificates", nargs=2,
                        metavar=("org=...", "days=..."),
                        help="Generate certificates, for example org=F+S days=365")
    parser.add_argument("--availableCerts", help="List available certificates", action="store_true")
    parser.add_argument("--configureBuild", nargs=5, metavar=("certs=...", "configFile=...", "machine=...", "image=...", "serverip=..."),
                        help="Configure the build for OTA")
    parser.add_argument("--uploadRaucUpdateBundle", nargs=3, metavar=( "machine=...", "bundle=...", "ip=..."),
                        help="Upload the RAUC update bundle for the specified build and machine and bundle")
    parser.add_argument("--getLocalIp", help="Get the local IP address", action="store_true")
    parser.add_argument("--configureBoard", nargs=4, metavar=("certs=...", "boardip=...","serverip=...", "machine=..."),
                        help="Configure the board for OTA")
    args = parser.parse_args()

    if args.hawkbit:
        arguments = parseNamedArguments(parser, "--hawkbit", args.hawkbit, ("action",))
        try:
            updater.hawkbit(arguments["action"])
        except ValueError as error:
            parser.error(f"--hawkbit {error}")
    elif args.generateCertificates:
        arguments = parseNamedArguments(parser, "--generateCertificates",
                                        args.generateCertificates, ("org", "days"))
        updater.generateCertificates(arguments["org"], arguments["days"])
    elif args.availableCerts:
        print(updater.availableCerts())
    elif args.configureBuild:
        arguments = parseNamedArguments(parser, "--configureBuild", args.configureBuild,
                                        ("certs", "machine", "image", "serverip", "configFile"))
        updater.configureBuild(arguments["certs"], arguments["machine"], arguments["image"], arguments["serverip"], arguments["configFile"])
    elif args.configureBoard:
        arguments = parseNamedArguments(parser, "--configureBoard", args.configureBoard,
                                        ("certs", "boardip", "serverip", "machine"))
        updater.configureBoard(arguments["certs"], arguments["boardip"], arguments["serverip"], arguments["machine"])
    elif args.uploadRaucUpdateBundle:
        arguments = parseNamedArguments(parser, "--uploadRaucUpdateBundle", args.uploadRaucUpdateBundle,
                                        ("machine", "bundle", "ip"))
        updater.uploadRaucUpdateBundle(arguments["machine"], arguments["bundle"], arguments["ip"])
    elif args.getLocalIp:
        print(updater.getLocalIp())
    else:
        parser.print_help()
