#!/usr/bin/env python3
"""보드 상주 세션 호스트(#364). 표준 라이브러리만 쓰고 Python 3.9에서 돈다(보드가 macOS CommandLineTools python3로 뜬다).

상주 세션(resident.py의 Residents)을 보드 서버가 아니라 이 호스트 프로세스가 쥔다. 보드는 화면일 뿐이라 `board.sh stop`·
플러그인 업데이트 뒤 재기동에도 세션 pid와 붙잡은 권한·질문이 그대로 남고, 다시 붙은 보드가 바로 보여 준다.

- 실행: `python3 -I resident_host.py` — 보드 서버가 필요할 때 분리해서 띄운다(start_new_session). 한 데이터 폴더에 하나만
  (host.lock flock). 상시 데몬이 아니다: 살아 있는 상주 세션도 보드 연결도 없으면 BOARD_HOST_IDLE초(기본 300) 뒤 스스로 끝난다.
  launchd 등록은 하지 않는다 — 재부팅 뒤에는 보드를 처음 열 때 보드가 띄운다.
- 새로 뜨면 사람이 끝내지 않은 KEEP_HOURS 안 세션을 같은 id로 --resume해 입력 대기로 둔다(Residents.resume_all).
- 대화: `$HARNESS_METRICS_DIR/board/host/` (0700) 아래 유닉스 소켓(0600)으로 JSON 한 줄 요청 → 한 줄 답. 요청마다
  host.json(0600)의 토큰을 실어야 하고, 연결한 쪽 uid가 같아야 한다(확인할 수 있는 OS에서). 경로가 소켓 길이 한도
  (macOS 104바이트)를 넘으면 임시 폴더 아래 사용자 전용 폴더(0700, 소유자 확인)에 소켓을 둔다.
- 요청 {"t", "op", ...}: start·send·decide·answer·end·mark_seen·owns·items·item, 그리고 subscribe(연결을 열어 둔 채
  상태가 바뀔 때마다 {"ev": "changed"} 한 줄을 받는다 — 보드는 그때 SSE 비교를 깨운다).
보드 쪽은 HostClient가 Residents와 같은 메서드로 감싼다.
"""
import fcntl, hashlib, json, os, secrets, signal, socket, stat, struct, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import resident as hresident  # noqa: E402

SCRIPT = os.path.abspath(__file__)
SOCK_MAX = 100  # sun_path 한도(macOS 104, Linux 108)보다 조금 작게
MAX_LINE = 1 << 20


def _secure_dir(path):
    """0700 폴더를 만들고, 심볼릭 링크가 아니고 내 것인지 확인한다. 아니면 OSError."""
    os.makedirs(path, mode=0o700, exist_ok=True)
    st = os.lstat(path)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
        raise OSError(f"host folder is not a private directory: {path}")
    if st.st_mode & 0o777 != 0o700:
        os.chmod(path, 0o700)
    return path


class Paths:
    def __init__(self, data):
        self.dir = os.path.join(data, "board", "host")
        self.info = os.path.join(self.dir, "host.json")
        self.lock = os.path.join(self.dir, "host.lock")
        self.log = os.path.join(self.dir, "host.log")
        sock = os.path.join(self.dir, "host.sock")
        if len(sock.encode()) > SOCK_MAX:
            key = hashlib.sha256(os.path.abspath(data).encode()).hexdigest()[:12]
            sock = os.path.join(tempfile.gettempdir(), f"ai-harness-{os.getuid()}-{key}", "host.sock")
        self.sock = sock


def _peer_uid(conn):
    """연결한 프로세스의 uid. 알 수 없으면 None(토큰만으로 판단)."""
    try:
        if hasattr(socket, "SO_PEERCRED"):  # Linux: struct ucred {pid, uid, gid}
            return struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[1]
        if sys.platform == "darwin":  # SOL_LOCAL=0, LOCAL_PEERCRED=1 → struct xucred {u_int version; uid_t uid; ...}
            return struct.unpack("2I", conn.getsockopt(0, 1, 76)[:8])[1]
    except OSError:
        return None
    return None


def _read_line(conn, buf=b""):
    while b"\n" not in buf:
        got = conn.recv(65536)
        if not got:
            return None, b""
        buf += got
        if len(buf) > MAX_LINE:
            return None, b""
    line, rest = buf.split(b"\n", 1)
    return line, rest


def _send(conn, obj):
    conn.sendall(json.dumps(obj, ensure_ascii=False).encode() + b"\n")


def _load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


# ---------------------------------------------------------------- 호스트
class Host:
    def __init__(self, data, idle):
        self.paths = Paths(data)
        self.idle = idle
        self.token = secrets.token_urlsafe(24)
        self._subs = []
        self._subs_lock = threading.Lock()
        self._send_lock = threading.Lock()
        self._inflight = 0
        self._quiet_since = time.time()
        self._resuming = True  # 새로 뜬 호스트가 이어 쥘 세션을 다 띄우기 전에는 스스로 끝나지 않는다
        self.res = hresident.Residents(data, self.notify)
        self.srv = None

    def notify(self):
        """붙은 보드마다 한 줄. 세션 읽기 스레드가 부르므로 멈춘 보드에 오래 묶이지 않게 구독 소켓은 timeout이 있고,
        여러 스레드의 줄이 섞이지 않게 한 번에 하나만 쓴다."""
        with self._subs_lock:
            subs = list(self._subs)
        with self._send_lock:
            for conn in subs:
                try:
                    _send(conn, {"ev": "changed"})
                except OSError:
                    self._drop(conn)

    def _drop(self, conn):
        with self._subs_lock:
            if conn in self._subs:
                self._subs.remove(conn)
        try:
            conn.close()
        except OSError:
            pass

    def _subscribers(self):
        with self._subs_lock:
            return len(self._subs)

    def serve(self):
        _secure_dir(self.paths.dir)
        if os.path.dirname(self.paths.sock) != self.paths.dir:
            try:
                _secure_dir(os.path.dirname(self.paths.sock))
            except OSError:  # 공용 임시 폴더에 남이 같은 이름을 먼저 만들었다 — 무작위 이름으로(보드는 host.json의 sock으로 찾는다)
                self.paths.sock = os.path.join(tempfile.mkdtemp(prefix=f"ai-harness-{os.getuid()}-"), "host.sock")
        lockf = open(self.paths.lock, "a")
        try:
            fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return 0  # 다른 호스트가 이미 떠 있다
        self._lockf = lockf
        if os.path.exists(self.paths.sock):  # 잠금을 쥐었으니 남은 소켓은 죽은 호스트의 것
            os.unlink(self.paths.sock)
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        old = os.umask(0o177)
        try:
            self.srv.bind(self.paths.sock)
        finally:
            os.umask(old)
        os.chmod(self.paths.sock, 0o600)
        self.srv.listen(16)
        tmp = self.paths.info + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"pid": os.getpid(), "sock": self.paths.sock, "token": self.token, "started": hresident.utc()}, f)
        os.replace(tmp, self.paths.info)
        signal.signal(signal.SIGTERM, lambda *_: self.stop(term=True))
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        threading.Thread(target=self._resume, daemon=True).start()
        threading.Thread(target=self._idle_watch, daemon=True).start()
        while True:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return 0
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def stop(self, term=False):
        """소켓·기록을 지우고 끝난다. SIGTERM(로그아웃 등)이면 쥔 세션의 stdin을 닫고 잠깐 기다린 뒤 도구 하위 프로세스까지
        끝낸다. 사람이 끝낸 것으로 기록하지 않으므로 다음 호스트가 이어 쥔다."""
        if term:
            try:
                self.res.shutdown(grace=3.0)
            except Exception:
                pass
        info = _load_json(self.paths.info)
        if info and info.get("pid") == os.getpid():
            for p in (self.paths.info, self.paths.sock):
                try:
                    os.unlink(p)
                except OSError:
                    pass
            if os.path.dirname(self.paths.sock) != self.paths.dir:  # 경로가 길어 임시 폴더에 둔 소켓 폴더
                try:
                    os.rmdir(os.path.dirname(self.paths.sock))
                except OSError:
                    pass
        os._exit(0)

    def _resume(self):
        try:
            self.res.resume_all()
        finally:
            self._resuming = False

    def _idle_watch(self):
        step = max(0.2, min(5.0, self.idle / 4))
        while True:
            time.sleep(step)
            if self._resuming or self._inflight or self.res.live_count() or self._subscribers():
                self._quiet_since = time.time()
            elif time.time() - self._quiet_since >= self.idle:
                self.stop()

    def _handle(self, conn):
        conn.settimeout(30)
        with self._subs_lock:  # 처리 중인 요청이 있는 동안 스스로 끝나지 않게
            self._inflight += 1
            self._quiet_since = time.time()
        try:
            line, _ = _read_line(conn)
            req = json.loads(line) if line else None
            uid = _peer_uid(conn)
            if not isinstance(req, dict) or (uid is not None and uid != os.getuid()) \
                    or not secrets.compare_digest(str(req.get("t") or ""), self.token):
                _send(conn, {"ok": False, "message": "not authorized"})
                conn.close()
                return
            if req.get("op") == "subscribe":
                conn.settimeout(5)  # notify의 쓰기가 멈춘 보드에 묶이지 않게
                with self._send_lock:
                    _send(conn, {"ok": True})
                    with self._subs_lock:
                        self._subs.append(conn)
                while True:  # 보드가 연결을 닫을 때까지
                    try:
                        if not conn.recv(4096):
                            break
                    except socket.timeout:
                        continue
                self._drop(conn)
                return
            _send(conn, {"ok": True, "r": self._call(req)})
        except (OSError, ValueError):
            pass
        finally:
            with self._subs_lock:
                held = conn in self._subs
                self._inflight -= 1
                self._quiet_since = time.time()
            if not held:
                try:
                    conn.close()
                except OSError:
                    pass

    def _call(self, req):
        r, op = self.res, req.get("op")
        if op == "start":
            return r.start(req.get("cwd"), req.get("prompt"), req.get("name"))
        if op == "send":
            return r.send(req.get("id"), req.get("text"))
        if op == "decide":
            return r.decide(req.get("pid"), req.get("decision"))
        if op == "answer":
            return r.answer(req.get("id"), req.get("pid"), req.get("answers"))
        if op == "end":
            return r.end(req.get("id"))
        if op == "mark_seen":
            return r.mark_seen(req.get("ids") if isinstance(req.get("ids"), list) else [])
        if op == "owns":
            return r.owns(req.get("pid"))
        if op == "items":
            return r.items()
        if op == "item":
            return r.item(req.get("id"))
        return {"ok": False, "message": "unknown op"}


# ---------------------------------------------------------------- 보드 쪽
class _Unreachable(OSError):
    """소켓에 연결부터 못 했다 — 요청은 호스트에 닿지 않았다."""


class HostClient:
    """보드 서버가 쓰는 Residents 대역. 호스트가 없으면 필요할 때(새 세션·보내기·이어 쥘 세션이 있을 때) 띄운다.
    호스트가 없을 때 목록은 기록(residents.json)을 읽어 끝난 세션으로 보인다."""

    def __init__(self, data, notify):
        self.data, self.notify = data, notify
        self.paths = Paths(data)
        self._spawn_lock = threading.Lock()
        self._stopped = False
        self._started = False
        self._sub = None
        self._local = (None, None)
        self._verified = None
        self.wanted = False

    def start_watch(self):
        """보드 서버가 뜰 때 한 번: 호스트가 떠 있거나 이어 쥘 세션이 있으면 붙는다(없으면 띄운다).
        모듈을 import만 해서는 호스트를 띄우지 않게 생성자와 나눈다."""
        if self._started:
            return
        self._started = True
        self.wanted = bool(self._info()) or self._resumable()
        threading.Thread(target=self._subscribe_loop, daemon=True).start()

    # ---- 연결 ----
    def _info(self):
        """host.json의 pid가 살아 있고 그 프로세스가 이 호스트일 때만(재부팅 뒤 재사용된 pid를 호스트로 보지 않게)."""
        info = _load_json(self.paths.info)
        if not info or not isinstance(info.get("pid"), int) or not isinstance(info.get("token"), str):
            return None
        try:
            os.kill(info["pid"], 0)
        except ProcessLookupError:
            return None
        except PermissionError:
            return None
        key = (info["pid"], info.get("started"))
        if key == self._verified:  # 한 번 확인한 호스트는 요청마다 ps를 띄우지 않는다
            return info
        try:
            cmd = subprocess.run(["ps", "-o", "command=", "-p", str(info["pid"])], capture_output=True, text=True,
                                 timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return info  # 확인하지 못하면 연결 시도로 가린다
        if os.path.basename(SCRIPT) not in cmd:
            return None
        self._verified = key
        return info

    def _connect(self, info, timeout):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect(info.get("sock") or self.paths.sock)
        except OSError as e:
            s.close()
            raise _Unreachable(str(e))
        return s

    def _rpc(self, info, req, timeout=40):
        s = self._connect(info, timeout)
        try:
            _send(s, {"t": info["token"], **req})
            line, _ = _read_line(s)
        finally:
            s.close()
        if not line:
            raise OSError("host closed")
        res = json.loads(line)
        if "r" not in res:
            raise OSError(res.get("message") or "host refused")
        return res["r"]

    def _call(self, req, spawn):
        """연결부터 못 한 경우에만 호스트를 띄워 다시 보낸다. 보낸 뒤 답을 못 받았으면 다시 보내지 않는다 —
        호스트가 이미 처리했을 수 있어(같은 글이 두 번, 새 세션이 둘) 오류로 돌려준다."""
        info = self._info()
        if info:
            try:
                return self._rpc(info, req)
            except _Unreachable:
                pass
        if not spawn:
            raise OSError("no host")
        info = self.ensure()
        if not info:
            raise OSError("host did not start")
        return self._rpc(info, req)

    def ensure(self):
        """호스트가 없으면 분리해서 띄우고 받을 준비가 될 때까지(5초) 기다린다."""
        with self._spawn_lock:
            self.wanted = True
            info = self._info()
            if info and self._ping(info):
                return info
            try:
                _secure_dir(self.paths.dir)
                fd = os.open(self.paths.log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
                proc = subprocess.Popen([sys.executable, "-I", SCRIPT], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                        stderr=fd, cwd=os.path.expanduser("~"), start_new_session=True, close_fds=True)
                os.close(fd)
            except OSError:
                return None
            threading.Thread(target=proc.wait, daemon=True).start()  # 먼저 끝나면 좀비로 남지 않게 거둔다
            end = time.time() + 5
            while time.time() < end:
                info = self._info()
                if info and self._ping(info):
                    return info
                time.sleep(0.05)
            return None

    def _ping(self, info):
        try:
            self._rpc(info, {"op": "owns", "pid": ""}, timeout=3)
            return True
        except (OSError, ValueError):
            return False

    def _subscribe_loop(self):
        """호스트의 변경 알림을 보드 SSE로 잇는다. 호스트가 죽으면(보드가 열려 있는 동안) 다시 띄운다.
        띄우거나 붙지 못하면 1초부터 60초까지 늘려 가며 다시 시도한다(뜨자마자 죽는 호스트를 계속 띄우지 않게)."""
        delay = 1.0
        while not self._stopped:
            info = self._info()
            if self.wanted and not (info and self._ping(info)):
                info = self.ensure()
            attached = False
            if info:
                try:
                    s = self._connect(info, 10)
                    _send(s, {"t": info["token"], "op": "subscribe"})
                    line, buf = _read_line(s)
                    if line and json.loads(line).get("ok"):
                        attached, delay = True, 1.0
                        self.wanted = True
                        self._sub = s
                        s.settimeout(None)
                        self.notify()
                        while not self._stopped:
                            line, buf = _read_line(s, buf)
                            if line is None:
                                break
                            self.notify()
                    s.close()
                except (OSError, ValueError):
                    pass
                self._sub = None
                if self._stopped:
                    return
                if attached:
                    self.notify()  # 호스트가 사라졌다 — 목록이 기록 보기로 바뀐다
            if not attached and self.wanted:
                delay = min(60.0, delay * 2)
            time.sleep(delay if self.wanted and not attached else 1.0)

    def shutdown(self):
        """보드가 꺼질 때: 호스트와 세션은 그대로 두고 연결만 닫는다."""
        self._stopped = True
        s = self._sub
        if s:
            try:
                s.shutdown(socket.SHUT_RDWR)
                s.close()
            except OSError:
                pass

    # ---- 기록 보기(호스트가 없을 때) ----
    def _resumable(self):
        cut = time.time() - hresident.KEEP_HOURS * 3600
        try:
            with open(os.path.join(self.data, "board", "residents.json"), encoding="utf-8") as f:
                reg = json.load(f)
        except (OSError, ValueError):
            return False
        return isinstance(reg, dict) and any(isinstance(r, dict) and r.get("closed") is False
                                             and hresident._epoch(r.get("at")) >= cut for r in reg.values())

    def _offline(self):
        path = os.path.join(self.data, "board", "residents.json")
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            return None
        if self._local[0] != mtime:
            self._local = (mtime, hresident.Residents(self.data, lambda: None))
        return self._local[1]

    # ---- Residents와 같은 메서드 ----
    def start(self, cwd, prompt, name=None):
        return self._safe({"op": "start", "cwd": cwd, "prompt": prompt, "name": name})

    def send(self, item_id, text):
        return self._safe({"op": "send", "id": item_id, "text": text})

    def decide(self, pid, decision):
        return self._safe({"op": "decide", "pid": pid, "decision": decision})

    def answer(self, item_id, pid, answers):
        return self._safe({"op": "answer", "id": item_id, "pid": pid, "answers": answers})

    def end(self, item_id):
        return self._safe({"op": "end", "id": item_id})

    def _safe(self, req):
        try:
            return self._call(req, spawn=True)
        except (OSError, ValueError) as e:
            return {"ok": False, "message": f"상주 세션 호스트에 닿지 못함 — {e}"}

    def mark_seen(self, ids):
        if ids:
            try:
                self._call({"op": "mark_seen", "ids": list(ids)}, spawn=False)
            except (OSError, ValueError):
                pass

    def owns(self, pid):
        if not (isinstance(pid, str) and pid.startswith("res-")):
            return False
        try:
            return self._call({"op": "owns", "pid": pid}, spawn=False) is True
        except (OSError, ValueError):
            return False

    def items(self):
        try:
            return self._call({"op": "items"}, spawn=False)
        except (OSError, ValueError):
            off = self._offline()
            return off.items() if off else []

    def item(self, item_id):
        try:
            return self._call({"op": "item", "id": item_id}, spawn=False)
        except (OSError, ValueError):
            off = self._offline()
            return off.item(item_id) if off else None


def main():
    data = os.environ.get("HARNESS_METRICS_DIR") or os.path.expanduser("~/.ai-harness")
    try:
        idle = float(os.environ.get("BOARD_HOST_IDLE", "300"))
    except ValueError:
        idle = 300.0
    return Host(data, idle if idle > 0 else 300.0).serve()


if __name__ == "__main__":
    sys.exit(main())
