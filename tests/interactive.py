"""Drive actual Bash prompts through a PTY; no production credentials or DNS."""
import errno
import hashlib
import json
import os
import pathlib
import pty
import re
import select
import shutil
import subprocess
import tempfile
import time

HOME = pathlib.Path(__file__).resolve().parents[1]
CLI = str(HOME / "bin/sb")
ROOT = pathlib.Path(tempfile.mkdtemp(prefix="sb-ui-"))
ENV = dict(os.environ, SB_ROOT=str(ROOT), SB_SERVICE_MODE="none", SB_CORE="/usr/local/bin/sb-core")


def run(*args, data=None):
    return subprocess.check_output([CLI, *args], env=ENV, input=data, text=True)


def records():
    return sorted((ROOT / "current/nodes").glob("*.json"))


def nodes():
    return [json.loads(p.read_text()) for p in records()]


def snapshot():
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in records()}


class Terminal:
    def __init__(self, *args, shell=None):
        self.master, slave = pty.openpty()
        argv = [CLI, *args] if shell is None else ["bash", "-c", shell]
        self.process = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, env=ENV)
        os.close(slave)
        self.output = b""
        self.position = 0

    def read(self, timeout=.1):
        if select.select([self.master], [], [], timeout)[0]:
            try:
                self.output += os.read(self.master, 65535)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise

    def expect(self, text, response=None, timeout=25):
        needle = text.encode()
        deadline = time.monotonic() + timeout
        while needle not in self.output[self.position:]:
            if time.monotonic() >= deadline:
                self.process.kill()
                raise AssertionError(f"Missing prompt {text!r}:\n{self.output.decode(errors='replace')}")
            self.read()
            if self.process.poll() is not None:
                self.read()
                if needle not in self.output[self.position:]:
                    raise AssertionError(f"Terminal exited {self.process.returncode}, expected {text!r}:\n{self.output.decode(errors='replace')}")
        self.position = self.output.index(needle, self.position) + len(needle)
        if response is not None:
            os.write(self.master, (response + "\n").encode())

    def finish(self, code=0):
        deadline = time.monotonic() + 25
        while self.process.poll() is None:
            self.read()
            if time.monotonic() >= deadline:
                self.process.kill()
                raise AssertionError(self.output.decode(errors="replace"))
        self.read()
        os.close(self.master)
        assert self.process.returncode == code, self.output.decode(errors="replace")
        return re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", self.output.decode(errors="replace"))


def choose(t, title, value):
    t.expect(title)
    t.expect("请选择序号: ", value)


def input_base(t, port, name):
    t.expect("公网端口（auto 自动分配）", port)
    t.expect("客户端连接地址（公网 IP 或域名）", "")
    t.expect("节点名称（可留空）", name)


def main():
    (ROOT / "rules").mkdir()
    shutil.copy("/opt/test-assets/geoip-cn.srs", ROOT / "rules/geoip-cn.srs")
    run("init", "--address", "127.0.0.1")
    assert nodes() == []

    t = Terminal()
    choose(t, "sb-manager 主菜单", "bad")
    t.expect("序号无效")
    choose(t, "sb-manager 主菜单", "1")
    t.expect("22) 端口转发")
    t.expect("请选择序号: ", "0")
    choose(t, "sb-manager 主菜单", "0")
    t.finish()
    assert nodes() == [], "Cancelled add created a node"
    print("PASS main loop, invalid choice, all 22 numbered protocols and cancel", flush=True)

    # Every displayed protocol ordinal maps to the real normalized protocol.
    shell = f'export SB_HOME={HOME}; source "$SB_HOME/lib/common.sh"; source "$SB_HOME/lib/ui.sh"; ui_protocol'
    expected = ["reality", "rh2", "ss", "tcp", "http", "ws", "quic", "wss", "h2", "hu", "vws", "vh2", "vhu", "trojan", "tws", "th2", "thu", "hy2", "tuic", "anytls", "socks", "door"]
    for i, alias in enumerate(expected, 1):
        t = Terminal(shell=shell)
        choose(t, "选择入口协议", str(i))
        output = t.finish()
        assert output.replace("\r", "").endswith(alias + "\n"), (i, output)
    print("PASS all numbered protocol choices map to supported aliases", flush=True)

    for ordinal, wanted in (("1", "apps.mzstatic.com"), ("2", "xp.apple.com")):
        t = Terminal(shell=f'export SB_HOME={HOME}; source "$SB_HOME/lib/common.sh"; source "$SB_HOME/lib/ui.sh"; ui_sni')
        choose(t, "选择 REALITY SNI", ordinal)
        assert t.finish().replace("\r", "").endswith(wanted + "\n")
    print("PASS numbered REALITY SNI presets", flush=True)

    t = Terminal("add")
    choose(t, "选择入口协议", "3")
    input_base(t, "28101", "ui-first")
    choose(t, "选择 Shadowsocks 加密方式", "5")
    t.expect("密码（auto 自动生成）", "secret-ui-password")
    choose(t, "保存这个节点？", "1")
    output = t.finish()
    assert "secret-ui-password" not in output
    assert len(nodes()) == 1 and nodes()[0]["password"] == "secret-ui-password"
    first = nodes()[0]["id"]
    t = Terminal("info", first)
    info = json.loads(t.finish())
    assert info == nodes()[0] and info["password"] == "secret-ui-password"
    t = Terminal("add", "ss")
    input_base(t, "28102", "ui-sibling")
    choose(t, "选择 Shadowsocks 加密方式", "5")
    t.expect("密码（auto 自动生成）", "")
    choose(t, "保存这个节点？", "1")
    t.finish()
    sibling = next(n["id"] for n in nodes() if n["id"] != first)
    stable = (ROOT / "current/nodes" / (sibling + ".json")).read_bytes()
    print("PASS add wizard, protocol shortcut, same-protocol independent nodes and hidden password", flush=True)

    t = Terminal()
    choose(t, "sb-manager 主菜单", "3")
    t.expect("选择节点序号: ", str(next(i for i, n in enumerate(nodes(), 1) if n["id"] == first)))
    choose(t, "查看节点", "1")
    t.expect("secret-ui-password")
    choose(t, "sb-manager 主菜单", "0")
    output = t.finish()
    assert "[REDACTED]" not in output
    print("PASS command and numbered information views show exact credential values", flush=True)

    t = Terminal("change", first)
    t.expect("选择修改项")
    assert "REALITY SNI" not in t.output.decode()
    t.expect("请选择序号: ", "1")
    t.expect("新的公网端口", "28103")
    t.finish()
    assert next(n for n in nodes() if n["id"] == first)["port"] == 28103
    assert (ROOT / "current/nodes" / (sibling + ".json")).read_bytes() == stable
    print("PASS numbered per-protocol edit menu and sibling isolation", flush=True)

    t = Terminal("name", first)
    t.expect("新的值", "renamed-ui-node")
    t.finish()
    t = Terminal("address", first)
    t.expect("新的值", "2001:db8::7")
    t.finish()
    selected = next(n for n in nodes() if n["id"] == first)
    assert selected["name"] == "renamed-ui-node" and selected["address"] == "2001:db8::7"
    t = Terminal("address", first)
    t.expect("新的值", "127.0.0.1")
    t.finish()
    print("PASS prompted name and client-address editing", flush=True)

    before = snapshot()
    t = Terminal("port", first)
    t.expect("新的公网端口", "28102")
    t.finish(1)
    assert snapshot() == before, "Port conflict mutated state"
    t = Terminal("outbound", first)
    choose(t, "选择节点出口", "2")
    link = "ss://YWVzLTI1Ni1nY206cGFzcw==@198.51.100.8:443"
    t.expect("粘贴出口链接", link)
    output = t.finish()
    assert link not in output
    assert next(n for n in nodes() if n["id"] == first)["outbound"]["type"] == "shadowsocks"
    t = Terminal("outbound", first)
    choose(t, "选择节点出口", "1")
    t.finish()
    assert next(n for n in nodes() if n["id"] == first)["outbound"]["type"] == "direct"
    print("PASS port conflict unchanged; numbered outbound copy and direct reset", flush=True)

    t = Terminal("new", first)
    choose(t, "选择入口协议", "4")
    input_base(t, "", "")
    t.expect("UUID（auto 自动生成）", "")
    choose(t, "保存这个节点？", "1")
    t.finish()
    changed = next(n for n in nodes() if n["id"] == first)
    assert changed["protocol"] == "vmess-tcp" and changed["port"] == 28103
    assert (ROOT / "current/nodes" / (sibling + ".json")).read_bytes() == stable
    print("PASS protocol switch keeps stable ID, port and sibling", flush=True)

    t = Terminal("add", "trojan")
    input_base(t, "28104", "ui-tls")
    t.expect("密码（auto 自动生成）", "")
    t.expect("你控制的证书域名", "example.test")
    choose(t, "该域名没有证书", "2")
    choose(t, "保存这个节点？", "1")
    t.finish()
    assert len(nodes()) == 3
    assert any(n["protocol"] == "trojan" for n in nodes())
    print("PASS explicit self-signed TLS workflow without an external domain", flush=True)

    t = Terminal("web")
    choose(t, "网站管理", "1")
    t.expect("没有使用受管 HTTP TLS 反代的节点")
    t.finish(2)
    web_node = json.loads(run("add", "vws", "example.test", "auto", "/ui", "--port", "28105"))
    t = Terminal("web")
    choose(t, "网站管理", "1")
    t.expect("选择可设置伪装的节点")
    text = t.output.decode(errors="replace")
    assert "trojan" not in text and "shadowsocks" not in text
    t.expect("请选择序号: ", "1")
    choose(t, "选择伪装页面", "1")
    t.finish()
    assert next(n for n in nodes() if n["id"] == web_node["id"])["web"] == ""
    print("PASS website menu only offers compatible HTTP TLS nodes", flush=True)

    t = Terminal("cert")
    choose(t, "证书管理", "4")
    t.expect("凭据名称", "ui-profile")
    token = "test_TOKEN_012345678901234567890"
    t.expect("Cloudflare API Token: ", token)
    output = t.finish()
    assert token not in output
    credentials = ROOT / "credentials/ui-profile.ini"
    assert credentials.stat().st_mode & 0o777 == 0o600
    print("PASS certificate menu and hidden root-only token input", flush=True)

    t = Terminal("dns")
    choose(t, "选择全局 DNS", "2")
    t.finish()
    assert json.loads((ROOT / "current/settings.json").read_text())["dns"]["server"] == "1.1.1.1"
    before = snapshot()
    t = Terminal("del", first)
    choose(t, "删除节点", "2")
    t.finish(2)
    assert snapshot() == before
    t = Terminal("del", first)
    choose(t, "删除节点", "1")
    t.finish()
    assert first not in [n["id"] for n in nodes()]
    t = Terminal("info")
    t.expect("选择节点序号: ", "0")
    t.finish(2)
    print("PASS DNS menu, deletion confirmation and node-selection cancellation", flush=True)

    # Open every other main-menu branch and cancel without invoking mutations.
    titles = {"7": "网站管理", "8": "选择服务", "9": "日志管理", "11": "备份、恢复和导入", "12": "选择更新对象", "13": "检查与维护"}
    t = Terminal()
    choose(t, "sb-manager 主菜单", "2")
    t.expect("选择节点序号: ", "1")
    choose(t, "选择修改项", "1")
    t.expect("新的公网端口", "invalid-port")
    t.expect("操作失败，原错误已显示")
    for value, title in titles.items():
        choose(t, "sb-manager 主菜单", value)
        choose(t, title, "0")
    choose(t, "sb-manager 主菜单", "0")
    t.finish()
    print("PASS website, service, log, backup, update and maintenance menus return cleanly", flush=True)
    print("INTERACTIVE PTY SUITE PASSED", flush=True)


try:
    main()
finally:
    shutil.rmtree(ROOT)
