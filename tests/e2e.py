"""Real multi-container protocol and transaction acceptance; no production credentials."""
import json
import os
import pathlib
import subprocess
import sys
import time
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROJECT = os.environ.get("SB_TEST_REUSE_PROJECT", "sb-e2e-" + str(os.getpid()))
CONTAINER_CODE = os.environ.get("SB_TEST_CONTAINER_CODE", "/workspace")
COMPOSE = ["docker", "compose", "-p", PROJECT, "-f", str(ROOT / "tests/docker/compose.yml")]
RESULTS = []


def command(args, data=None, check=True):
    result = subprocess.run(args, input=data, text=True, capture_output=True, cwd=ROOT)
    if check and result.returncode:
        raise RuntimeError(f"command failed: {args[:5]}\n{result.stdout[-2000:]}\n{result.stderr[-3000:]}")
    return result


def execute(service, args, data=None, check=True):
    args = [arg.replace("/workspace", CONTAINER_CODE) for arg in args]
    if data is not None:
        data = data.replace("/workspace", CONTAINER_CODE)
    return command(COMPOSE + ["exec", "-T", "--workdir", "/", service] + args, data, check)


def sb(service, *args, check=True):
    return execute(service, ["/workspace/bin/sb"] + list(args), check=check)


def script(service, body, args=()):
    return execute(service, ["bash", "-s", "--"] + list(args), "set -Eeuo pipefail\n" + body)


def service_ip(service):
    container = command(COMPOSE + ["ps", "-q", service]).stdout.strip()
    info = json.loads(command(["docker", "inspect", container]).stdout)[0]
    return next(iter(info["NetworkSettings"]["Networks"].values()))["IPAddress"]


def allow_fixture(service):
    # Add exactly the isolated target /32 to a TEST COPY of generated routing.
    # Production rendering has no test flag and always retains the default blocks.
    script(service, '''
cfg="$SB_ROOT/current/config.json"
jq --arg target "$1/32" '.route.rules = (.route.rules[:3] +
  [.route.rules[]|select(.action=="route" and .inbound!=null)|. + {ip_cidr:[$target]}] +
  .route.rules[3:])' "$cfg" > "$SB_ROOT/run/fixture.json"
cp "$SB_ROOT/run/fixture.json" "$cfg"
/workspace/bin/sb restart
''', (service_ip("target"),))


def configure_client(uri, pin=""):
    script("client", '''
export SB_HOME=/workspace SB_CORE=/usr/local/bin/sb-core
source /workspace/lib/common.sh
source /workspace/lib/links.sh
out=$(outbound_from_uri "$1")
if [[ -n ${2:-} ]]; then out=$(jq --arg pin "$2" '.tls.insecure=false|.tls.certificate_public_key_sha256=[$pin]' <<< "$out"); fi
jq -n --argjson out "$out" '{log:{level:"debug"},inbounds:[{type:"mixed",tag:"client",listen:"127.0.0.1",listen_port:1080}],outbounds:[$out+{tag:"proxy"}],dns:{servers:[{type:"local",tag:"dns"}]},route:{final:"proxy",default_domain_resolver:"dns"}}' > /state/client.json
if [[ -f /state/client.pid ]]; then kill "$(cat /state/client.pid)" 2>/dev/null || true; sleep .1; fi
nohup /usr/local/bin/sb-core run -c /state/client.json </dev/null >/state/client.log 2>&1 &
printf '%s\\n' "$!" > /state/client.pid
sleep .3
''', (uri, pin))


def http_ok():
    result = execute("client", ["curl", "--noproxy", "", "--fail", "--silent", "--show-error", "--max-time", "10", "--socks5-hostname", "127.0.0.1:1080", "http://target:8000/"])
    assert result.stdout == "sb-manager-e2e-ok\n", result.stdout


def udp_ok():
    execute("client", ["python3", "/workspace/tests/udp-client.py", "target"])


def record(name):
    RESULTS.append({"test": name, "status": "passed"})
    print("PASS", name, flush=True)


def add_args(protocol):
    args = ["--address", service_ip("server"), "--port", "31000", "--cert-domain", "example.test", "--skip-probe"]
    if protocol in ("wss", "h2", "hu", "vws", "vh2", "vhu", "tws", "th2", "thu"):
        args += ["example.test", "auto", "/tunnel"]
    elif protocol in ("r", "rh2"):
        args += ["auto", "auto", "target.test"]
    return args


def main():
    if not os.environ.get("SB_TEST_REUSE_PROJECT"):
        command(COMPOSE + ["up", "-d", "--wait"])
    time.sleep(.7)
    for service in ("server", "exit"):
        script(service, '''
mkdir -p "$SB_ROOT/rules"
cp /opt/test-assets/geoip-cn.srs "$SB_ROOT/rules/geoip-cn.srs"
/workspace/bin/sb init --address "$1"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj /CN=example.test -addext subjectAltName=DNS:example.test -keyout "$SB_ROOT/run/key.pem" -out "$SB_ROOT/run/cert.pem" >/dev/null 2>&1
/workspace/bin/sb cert import example.test "$SB_ROOT/run/cert.pem" "$SB_ROOT/run/key.pem" --self-signed
''', (service_ip(service),))
    first = json.loads(sb("server", "add", "ss", "31000", "auto", "aes-256-gcm").stdout)["id"]
    second = json.loads(sb("server", "add", "ss", "31001", "auto", "aes-256-gcm").stdout)["id"]
    stable = execute("server", ["cat", f"/state/manager/current/nodes/{second}.json"]).stdout
    configure_client(sb("server", "url", first).stdout.strip())
    denied = execute("client", ["curl", "--noproxy", "", "--fail", "--silent", "--max-time", "3", "--socks5-hostname", "127.0.0.1:1080", "http://target:8000/"], check=False)
    assert denied.returncode != 0, "production private-address block missing"
    record("production private target is rejected without a test exception")
    protocols = ["ss", "tcp", "http", "quic", "ws", "r", "rh2", "trojan", "hy2", "tuic", "anytls", "socks", "wss", "h2", "hu", "vws", "vh2", "vhu", "tws", "th2", "thu"]
    for protocol in protocols:
        sb("server", "new", first, protocol, *add_args(protocol))
        allow_fixture("server")
        configure_client(sb("server", "url", first).stdout.strip())
        http_ok()
        udp_ok()
        assert execute("server", ["cat", f"/state/manager/current/nodes/{second}.json"]).stdout == stable
        record(f"inbound {protocol}: TCP + UDP + shared-link client + independent sibling")
    sb("server", "new", first, "door", "31000", service_ip("target"), "8000", "--address", service_ip("server"))
    allow_fixture("server")
    result = execute("client", ["curl", "--fail", "--silent", "--max-time", "10", f"http://{service_ip('server')}:31000/"])
    assert result.stdout == "sb-manager-e2e-ok\n"
    record("door forwards TCP to the configured target")
    execute("client", ["python3", "-c", 'import socket,sys;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(5);s.sendto(b"sb-door-udp",(sys.argv[1],31000));assert s.recvfrom(65535)[0]==b"sb-door-udp"', service_ip("server")])
    record("door forwards UDP to the configured target")
    sb("server", "new", first, "ss", "31000", "auto", "aes-256-gcm")
    exit_id = json.loads(sb("exit", "add", "ss", "32000", "auto", "aes-256-gcm").stdout)["id"]
    for protocol in protocols:
        args = add_args(protocol)
        args[1] = service_ip("exit")
        args[3] = "32000"
        sb("exit", "new", exit_id, protocol, *args)
        allow_fixture("exit")
        uri = sb("exit", "url", exit_id).stdout.strip()
        sb("server", "outbound", first, uri)
        allow_fixture("server")
        configure_client(sb("server", "url", first).stdout.strip())
        http_ok(); udp_ok()
        record(f"outbound {protocol}: independent parsed copy, real TCP + UDP chain")
    sb("exit", "stop")
    failed = execute("client", ["curl", "--noproxy", "", "--fail", "--silent", "--max-time", "3", "--socks5-hostname", "127.0.0.1:1080", "http://target:8000/"], check=False)
    assert failed.returncode != 0
    record("failed proxy never falls back to direct")
    sb("server", "outbound", first, "direct"); allow_fixture("server")
    script("server", '''
cat > /state/fault-core <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == run ]] && jq -e 'any(.inbounds[];.listen_port==31999)' "$SB_ROOT/current/config.json" >/dev/null; then exit 42; fi
exec /usr/local/bin/sb-core "$@"
EOF
chmod +x /state/fault-core
''')
    previous = execute("server", ["readlink", "/state/manager/current"]).stdout
    failed = execute("server", ["env", "SB_CORE=/state/fault-core", "/workspace/bin/sb", "port", first, "31999"], check=False)
    assert failed.returncode != 0
    assert execute("server", ["readlink", "/state/manager/current"]).stdout == previous
    journal = json.loads(execute("server", ["cat", "/state/manager/transaction.json"]).stdout)
    assert journal["phase"] == "rolled-back", journal
    assert journal["new"] != journal["old"], journal
    http_ok()
    record("real process startup failure restores generation, service and connectivity")
    certificate_rotation(first)


def certificate_rotation(first):
    # Native TCP TLS replacement must serve the new certificate, not only update files.
    sb("server", "new", first, "trojan", "31000", "auto", "--cert-domain", "example.test")
    allow_fixture("server")
    old_fp = script("server", 'openssl x509 -in "$SB_ROOT/run/cert.pem" -noout -fingerprint -sha256').stdout
    script("server", '''
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj /CN=example.test -addext subjectAltName=DNS:example.test -keyout "$SB_ROOT/run/rotated.key" -out "$SB_ROOT/run/rotated.pem" >/dev/null 2>&1
/workspace/bin/sb cert import example.test "$SB_ROOT/run/rotated.pem" "$SB_ROOT/run/rotated.key" --self-signed
''')
    served = script("server", 'openssl s_client -connect 127.0.0.1:31000 -servername example.test </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256').stdout
    assert old_fp != served
    record("versioned native TLS rotation verified over a real handshake")
    for protocol in ("hy2", "tuic", "quic"):
        sb("server", "new", first, protocol, "31000", "auto", "--cert-domain", "example.test")
        script("server", '''
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj /CN=example.test -addext subjectAltName=DNS:example.test -keyout "$SB_ROOT/run/rotated.key" -out "$SB_ROOT/run/rotated.pem" >/dev/null 2>&1
/workspace/bin/sb cert import example.test "$SB_ROOT/run/rotated.pem" "$SB_ROOT/run/rotated.key" --self-signed
''')
        allow_fixture("server")
        pin = script("server", 'openssl x509 -in "$SB_ROOT/run/rotated.pem" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | base64 -w0').stdout.strip()
        configure_client(sb("server", "url", first).stdout.strip(), pin)
        http_ok(); udp_ok()
        record(f"{protocol}: renewed certificate verified with the new public-key pin")


if __name__ == "__main__":
    status = 0
    try:
        if os.environ.get("SB_TEST_CERT_ONLY"):
            nodes = json.loads(sb("server", "list").stdout)
            certificate_rotation(next(node["id"] for node in nodes if node["port"] == 31000))
        else:
            main()
    except Exception as error:
        status = 1
        print(str(error), file=sys.stderr)
        for service in ("server", "exit", "client"):
            output = execute(service, ["bash", "-c", "tail -n 35 /state/manager/logs/core.log /state/manager/logs/nginx-error.log /state/client.log 2>/dev/null || true"], check=False)
            print(service, output.stdout[-8000:], file=sys.stderr)
    finally:
        directory = ROOT / ".test-output"
        directory.mkdir(exist_ok=True)
        report = "certificate-e2e.json" if os.environ.get("SB_TEST_CERT_ONLY") else "e2e.json"
        result = json.dumps({"passed": RESULTS, "exit_code": status}, indent=2)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
        (directory / f"{stamp}-{os.getpid()}-{report}").write_text(result)
        (directory / report).write_text(result)
        if status == 0:
            (directory / f"last-success-{report}").write_text(result)
        if not os.environ.get("SB_TEST_REUSE_PROJECT"):
            command(COMPOSE + ["down", "-v", "--remove-orphans"], check=False)
    sys.exit(status)
