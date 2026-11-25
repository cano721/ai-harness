"""tests/run.sh --profile 도우미. 영역 하나를 띄워 출력을 그대로 흘리면서 블록 시간을 잰다.

run <area> <tsv> <cmd...>: 영역 명령의 stdout·stderr를 한 줄씩 그대로 내보내고, `ok ` 줄이 도착할 때마다
직전 ok(첫 블록은 시작)부터 걸린 초를 <tsv>에 `초<TAB>영역<TAB>ok 줄`로 남긴다. 종료 코드는 영역의 것이다.
bash 3.2·macOS에는 소수점 초 시계가 없어 단조 시계(time.monotonic)를 쓰는 프로세스를 영역당 하나만 띄운다.
report <n> <dir>: <dir>/*.tsv를 모아 느린 순서로 최대 n줄을 `#   <초>s <영역> <ok 줄>`로 낸다.
"""
import os
import signal
import subprocess
import sys
import time


def run(area, tsv, cmd):
    last = time.monotonic()
    child = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def forward(signum, _frame):
        child.send_signal(signum)

    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGINT, forward)
    out = sys.stdout.buffer
    with open(tsv, "w", encoding="utf-8") as rec:
        for raw in iter(child.stdout.readline, b""):
            out.write(raw)
            out.flush()
            if raw.startswith(b"ok "):
                now = time.monotonic()
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                rec.write("%.3f\t%s\t%s\n" % (now - last, area, line.replace("\t", " ")))
                rec.flush()
                last = now
    rc = child.wait()
    if rc < 0:
        return 128 - rc
    return rc


def report(limit, directory):
    rows = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".tsv"):
            continue
        with open(os.path.join(directory, name), encoding="utf-8") as f:
            for row in f:
                parts = row.rstrip("\n").split("\t", 2)
                if len(parts) == 3:
                    rows.append((float(parts[0]), parts[1], parts[2]))
    rows.sort(key=lambda r: -r[0])
    print("# profile: slowest blocks")
    for secs, area, line in rows[:limit]:
        print("#   %.1fs %s %s" % (secs, area, line))
    return 0


def main(argv):
    if len(argv) >= 4 and argv[0] == "run":
        return run(argv[1], argv[2], argv[3:])
    if len(argv) == 3 and argv[0] == "report":
        return report(int(argv[1]), argv[2])
    sys.stderr.write("usage: profile-blocks.py run <area> <tsv> <cmd...> | report <n> <dir>\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
