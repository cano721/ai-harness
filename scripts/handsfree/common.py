"""설정·상태 파일, 알림, 음성 출력. 사용자 설정이 기본값을 덮는다."""
import contextlib
import fcntl
import json
import os
import shutil
import subprocess
import time

CODE_DIR = os.path.dirname(os.path.abspath(__file__))
# 사용자 데이터는 하네스 공용 위치(~/.ai-harness) 아래에 둔다. 테스트는 HM_DATA_DIR 로 바꾼다.
DATA_DIR = os.environ.get("HM_DATA_DIR") or os.path.expanduser("~/.ai-harness")
HOME_DIR = os.path.join(DATA_DIR, "handsfree")
CONFIG_PATH = os.path.join(HOME_DIR, "config.json")
STATE_PATH = os.path.join(HOME_DIR, "state.json")
PID_PATH = os.path.join(HOME_DIR, "listener.pid")
LOG_PATH = os.path.join(HOME_DIR, "handsfree.log")
PAUSED_PATH = os.path.join(HOME_DIR, "paused")
SAY_LOCK = os.path.join(HOME_DIR, "say.lock")
SPOKEN_PATH = os.path.join(HOME_DIR, "spoken")
SESSION_DIR = os.path.join(HOME_DIR, "sessions")
MODEL_DIR = os.path.join(HOME_DIR, "models")
BIN_DIR = os.path.join(HOME_DIR, "bin")
FOREVER = 9999999999


def ensure_private_dir(path):
    """handsfree 데이터 경로를 소유자 전용으로 만든다. 공용 ~/.ai-harness 는 새로 만들 때만 권한을 정한다."""
    if not os.path.isdir(DATA_DIR):
        os.makedirs(DATA_DIR, mode=0o700, exist_ok=True)
        os.chmod(DATA_DIR, 0o700)
    for folder in (HOME_DIR, path):
        os.makedirs(folder, mode=0o700, exist_ok=True)
        os.chmod(folder, 0o700)


def open_private(path, mode="w", encoding=None):
    """새 사용자 데이터 파일은 umask와 무관하게 소유자 전용으로 연다."""
    flags = {"w": os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
             "a": os.O_WRONLY | os.O_CREAT | os.O_APPEND,
             "wb": os.O_WRONLY | os.O_CREAT | os.O_TRUNC}[mode]
    fd = os.open(path, flags, 0o600)
    os.fchmod(fd, 0o600)
    return os.fdopen(fd, mode) if "b" in mode else os.fdopen(fd, mode, encoding=encoding)


def whisper_binary():
    local = os.path.join(BIN_DIR, "whisper-server")
    return local if os.path.exists(local) else shutil.which("whisper-server")


def read_json(path, fallback):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return fallback


def write_json(path, data):
    ensure_private_dir(os.path.dirname(path))
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open_private(tmp, encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def user_config():
    """(설정, 정상 여부). 파일이 깨졌으면 기본값으로 조용히 돌아가지 않도록 알려 준다."""
    if not os.path.exists(CONFIG_PATH):
        return {}, True
    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            data = json.load(f)
        return (data, True) if isinstance(data, dict) else ({}, False)
    except (OSError, ValueError):
        return {}, False


@contextlib.contextmanager
def locked(path):
    """읽고-고치고-쓰는 동안 다른 프로세스(세션마다 도는 훅, 상태 화면)가 끼어들지 못하게 한다."""
    ensure_private_dir(os.path.dirname(path))
    with open_private(path + ".lock") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def load_config():
    cfg = read_json(os.path.join(CODE_DIR, "defaults.json"), {})
    user, ok = user_config()
    cfg["config_broken"] = not ok
    for key, value in user.items():
        if key in ("commands", "macros") and isinstance(value, dict):
            merged = dict(cfg.get(key, {}))
            merged.update(value)
            cfg[key] = merged
        else:
            cfg[key] = value
    return cfg


def set_user_config(key, value):
    """깨진 설정 파일은 덮어쓰지 않는다. 저장했으면 True."""
    return update_user_config({key: value})


def update_user_config(changes):
    """여러 값을 한 번에 저장한다. 값이 None 이면 그 키를 지워 기본값으로 돌린다."""
    with locked(CONFIG_PATH):
        user, ok = user_config()
        if not ok:
            return False
        for key, value in changes.items():
            if value is None:
                user.pop(key, None)
            else:
                user[key] = value
        write_json(CONFIG_PATH, user)
        return True


def load_state():
    return read_json(STATE_PATH, {})


def update_state(**changes):
    with locked(STATE_PATH):
        state = load_state()
        state.update(changes)
        write_json(STATE_PATH, state)


def session_file(handle):
    """세션별 기록(마지막 답변, 승인 요청 내용)."""
    return os.path.join(SESSION_DIR, handle + ".json")


def update_session(handle, **changes):
    with locked(session_file(handle)):
        data = read_json(session_file(handle), {})
        data.update(changes)
        write_json(session_file(handle), data)


def log(message):
    ensure_private_dir(HOME_DIR)
    try:
        if os.path.getsize(LOG_PATH) > 1000000:
            os.replace(LOG_PATH, LOG_PATH + ".1")
    except OSError:
        pass
    with open_private(LOG_PATH, "a", encoding="utf-8") as f:
        f.write(time.strftime("%m-%d %H:%M:%S ") + message + "\n")


def notify(title, body):
    args = ["osascript"]
    for line in ("on run argv",
                 "display notification (item 2 of argv) with title (item 1 of argv)",
                 "end run"):
        args += ["-e", line]
    subprocess.Popen(args + [title, body[:300]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def in_quiet_hours(cfg, now=None):
    if not cfg.get("quiet_hours"):
        return False
    hour = time.localtime(now).tm_hour if now else time.localtime().tm_hour
    start, end = int(cfg.get("quiet_from", 22)), int(cfg.get("quiet_to", 7))
    return start <= hour < end if start < end else hour >= start or hour < end


def volume(cfg, kind="speech"):
    """소리 크기(0~1). 조용한 시간에는 끄지 않고 작게만 낸다. 하지 않은 일은 소리로 알린다는 규칙 때문이다."""
    base = float(cfg.get("speech_volume" if kind == "speech" else "beep_volume", 1.0))
    if in_quiet_hours(cfg):
        base = min(base, float(cfg.get("quiet_volume", 0.25)))
    return max(0.0, min(1.0, base))


def beep(name="Tink"):
    level = volume(load_config(), "beep")
    if level <= 0:
        return
    subprocess.Popen(
        ["afplay", "-v", "%.2f" % level, "/System/Library/Sounds/%s.aiff" % name],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def listener_pid():
    try:
        with open(PID_PATH) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
    except (OSError, ValueError):
        return None
    # pid 파일이 남은 채 번호가 다른 프로세스에 재사용됐을 수 있다.
    command = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
    return pid if "listener.py" in command else None


def paused_until():
    try:
        with open(PAUSED_PATH) as f:
            until = int(f.read().strip())
    except (OSError, ValueError):
        return 0
    return until if until > time.time() else 0


def set_paused(until):
    if until:
        ensure_private_dir(HOME_DIR)
        with open_private(PAUSED_PATH) as f:
            f.write(str(int(until)))
    else:
        try:
            os.remove(PAUSED_PATH)
        except OSError:
            pass


def say(text, cfg):
    """여러 세션이 동시에 말하지 않게 한 줄로 세워 읽는다."""
    text = " ".join(text.split()).lstrip("- ").replace("[[", "[ [")
    level = volume(cfg)
    if not text or level <= 0:
        return
    text = "[[volm %.2f]] %s" % (level, text)
    try:
        # 읽던 프로세스가 죽어 남은 잠금만 치운다. 길게 읽는 중인 잠금은 건드리지 않는다.
        if time.time() - os.path.getmtime(SAY_LOCK) > 5 and not is_speaking():
            shutil.rmtree(SAY_LOCK, ignore_errors=True)
    except OSError:
        pass
    script = ('while ! mkdir "$4" 2>/dev/null; do sleep 0.3; done; '
              'say -v "$1" -r "$2" "$3"; touch "$5"; rmdir "$4"')
    subprocess.Popen(
        ["/bin/sh", "-c", script, "handsfree-say",
         str(cfg.get("tts_voice", "Yuna")), str(cfg.get("tts_rate", 210)), text, SAY_LOCK, SPOKEN_PATH],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def stop_speaking():
    subprocess.run(["pkill", "-f", "handsfree-say"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["killall", "say"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(SAY_LOCK, ignore_errors=True)


def is_speaking():
    return subprocess.run(["pgrep", "-x", "say"], stdout=subprocess.DEVNULL).returncode == 0


def spoke_since(moment):
    """그 시각 이후로 읽어 준 소리가 있었는지. 녹음에 제 목소리가 섞였는지 가릴 때 쓴다."""
    try:
        return is_speaking() or os.path.getmtime(SPOKEN_PATH) > moment
    except OSError:
        return is_speaking()
