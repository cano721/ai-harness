#!/usr/bin/env python3
"""GA4 Data API 조회 CLI (읽기 전용, scope analytics.readonly). 표준 라이브러리 + openssl 만 쓴다.

설정(langfuse lf.py 와 같은 순서): 프로세스 env → ~/.claude/settings.json 의 "env" →
${HARNESS_METRICS_DIR:-~/.ai-harness}/secrets.env.
  GA_KEY_FILE            서비스 계정 JSON 키 경로(경로는 비밀이 아니고 파일 내용이 비밀). 권한은 0600/0400 이어야 한다.
  GA_PROPERTY_ID         숫자 속성 ID(G-XXXX 측정 ID 아님)
  GA_PROPERTY_<별칭>      다른 속성 → --prop <별칭> (별칭 checkout-web → GA_PROPERTY_CHECKOUT_WEB)

키 파일은 서명할 때만 읽고 내용을 출력하지 않는다. 출력하는 것은 서비스 계정 이메일(client_email)뿐이다 —
GA 속성에 뷰어로 넣을 주소라서. 액세스 토큰은 ${HARNESS_METRICS_DIR:-~/.ai-harness}/cache/ga-token.json(0600)에
키 파일별로 캐시한다.

  ga.py report   --days 7 --metrics activeUsers,sessions --dims date [--filter 'eventName==sign_up'] [--order -activeUsers]
  ga.py report   --start 2026-11-01 --end 2026-11-25 --metrics eventCount --dims eventName
  ga.py realtime --metrics activeUsers [--dims unifiedScreenName]
  ga.py meta     [검색어]
  ga.py raw      '<runReport JSON 본문>'
  ga.py aliases                      # 등록된 속성 별칭(속성 ID)과 키 파일 상태
  ga.py check [--json]               # 키 파일·토큰·속성 접근 확인 (속성 metadata 조회)
"""
import argparse
import base64
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

SCOPE = "https://www.googleapis.com/auth/analytics.readonly"
API = "https://analyticsdata.googleapis.com/v1beta"
DATA_DIR = os.environ.get("HARNESS_METRICS_DIR") or os.path.expanduser("~/.ai-harness")
SECRETS_FILE = os.path.join(DATA_DIR, "secrets.env")
TOKEN_CACHE = os.path.join(DATA_DIR, "cache", "ga-token.json")
SETTINGS_FILE = os.environ.get("HARNESS_CLAUDE_SETTINGS") or os.path.expanduser("~/.claude/settings.json")
FILTER_OPS = (("!=", "EXACT"), ("==", "EXACT"), ("=~", "CONTAINS"), ("^=", "BEGINS_WITH"))


class GaError(Exception):
    """사용자에게 보여 줄 오류. code 는 check --json 의 error 값(HTTP 403·key file not found 등)."""

    def __init__(self, code, message, reason=""):
        super().__init__(message)
        self.code, self.reason = code, reason


def secrets_env():
    out = {}
    try:
        with open(SECRETS_FILE) as f:
            for line in f:
                m = re.fullmatch(r"export ([A-Z0-9_]+)='(.*)'", line.rstrip("\n"))
                if m:
                    out[m.group(1)] = m.group(2).replace("'\\''", "'")
    except OSError:
        pass
    return out


def settings_env():
    merged = secrets_env()
    try:
        with open(SETTINGS_FILE) as f:
            merged.update(json.load(f).get("env", {}) or {})
    except (OSError, ValueError, AttributeError):
        pass
    return merged


def lookup(name, files=None):
    return os.environ.get(name) or (settings_env() if files is None else files).get(name)


def suffix(alias):
    return "_" + alias.upper().replace("-", "_")


def aliases():
    """{별칭 또는 "" (기본): 속성 ID}"""
    found = {}
    for n, v in list(settings_env().items()) + list(os.environ.items()):
        m = re.fullmatch(r"GA_PROPERTY_(?:ID|([A-Z0-9_]+))", n)
        if m and v:
            found[m.group(1).lower().replace("_", "-") if m.group(1) else ""] = v
    return found


def property_id(alias):
    if alias and not re.fullmatch(r"[a-z0-9][a-z0-9-]*", alias):
        raise GaError("bad alias", "alias: lowercase letters, digits and '-' only")
    if alias == "id":
        raise GaError("bad alias", "alias 'id' is reserved: GA_PROPERTY_ID is the default property")
    name = "GA_PROPERTY" + suffix(alias) if alias else "GA_PROPERTY_ID"
    prop = lookup(name)
    if not prop:
        known = ", ".join(a or "(default)" for a in sorted(aliases())) or "none"
        # 별칭을 줬는데 없으면 기본 속성으로 대신하지 않는다 — 다른 속성 숫자를 그 속성 것으로 오인하지 않게.
        raise GaError("missing property", f"{name} not set. Registered: {known}")
    prop = prop.strip()
    if not re.fullmatch(r"[0-9]+", prop):
        raise GaError("bad property", f"{name} must be the numeric property ID (Admin > Property details), not a G-XXXX measurement ID")
    return prop


def key_file():
    path = lookup("GA_KEY_FILE")
    if not path:
        raise GaError("missing GA_KEY_FILE", "GA_KEY_FILE not set (path to the service account JSON key)")
    path = os.path.expanduser(path.strip())
    if not os.path.isfile(path):
        raise GaError("key file not found", f"key file not found: {path}")
    mode = stat.S_IMODE(os.stat(path).st_mode)
    if mode & 0o077:
        raise GaError("key file permissions", f"key file is readable by others ({oct(mode)}): chmod 600 {path}")
    return path


def load_key(path):
    try:
        with open(path) as f:
            sa = json.load(f)
    except (OSError, ValueError):
        raise GaError("bad key file", "key file is not valid JSON (content not shown)")
    if not (isinstance(sa, dict) and sa.get("type") == "service_account"
            and all(isinstance(sa.get(k), str) and sa.get(k) for k in ("client_email", "private_key", "token_uri"))):
        raise GaError("bad key file", "key file is not a service account key (type service_account, client_email, private_key, token_uri)")
    return sa


def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def write_private(path, data):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def cached_token(path):
    try:
        with open(TOKEN_CACHE) as f:
            c = json.load(f)
        if c.get("key_file") == path and c.get("key_mtime") == os.path.getmtime(path) and c["exp"] > time.time() + 60:
            return c["token"]
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None


def sign(private_key, data):
    # 개인키는 하네스 데이터 디렉터리의 0700 폴더 안 0600 임시 파일로만 openssl 에 넘기고 바로 지운다
    # (명령 인자·환경·공용 /tmp 에 싣지 않는다).
    # 임시 파일 쓰기 실패·openssl 실행 불가·서명 실패는 조치가 달라 오류 코드를 나눈다(#655).
    tmp_dir = os.path.join(DATA_DIR, "cache", "ga-sign")  # ga 전용 폴더 — 공용 cache 폴더 권한은 건드리지 않는다
    try:
        os.makedirs(tmp_dir, mode=0o700, exist_ok=True)
        os.chmod(tmp_dir, 0o700)
        fd, kp = tempfile.mkstemp(prefix="ga_", suffix=".pem", dir=tmp_dir)
    except OSError as e:
        raise GaError("key temp file failed", f"cannot write a private temp key file in {tmp_dir}: {e.strerror}")
    try:
        try:
            with os.fdopen(fd, "w") as f:
                f.write(private_key)
        except OSError as e:
            raise GaError("key temp file failed", f"cannot write a private temp key file in {tmp_dir}: {e.strerror}")
        try:
            r = subprocess.run(["openssl", "dgst", "-sha256", "-sign", kp], input=data, capture_output=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as e:
            raise GaError("openssl not available", f"openssl not available: {e}")
    finally:
        try:
            os.remove(kp)
        except FileNotFoundError:
            pass
    if r.returncode:
        raise GaError("openssl failed", "openssl could not sign with the key (content not shown)")
    return r.stdout


def access_token(path, sa):
    token = cached_token(path)
    if token:
        return token
    now = int(time.time())
    header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    claim = b64url(json.dumps({"iss": sa["client_email"], "scope": SCOPE, "aud": sa["token_uri"],
                               "iat": now, "exp": now + 3600}).encode())
    signing_input = f"{header}.{claim}".encode()
    jwt = f"{header}.{claim}.{b64url(sign(sa['private_key'], signing_input))}"
    data = urllib.parse.urlencode({"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": jwt}).encode()
    try:
        with urllib.request.urlopen(sa["token_uri"], data, timeout=30) as r:
            res = json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        raise GaError("token request failed", f"token request failed HTTP {e.code}: {body[:300]}", error_reason(body))
    except (urllib.error.URLError, OSError) as e:
        raise GaError("HTTP 000", f"cannot reach token endpoint: {getattr(e, 'reason', e)}")
    if not isinstance(res, dict) or not res.get("access_token"):
        raise GaError("token request failed", "token response has no access_token")
    try:
        write_private(TOKEN_CACHE, {"key_file": path, "key_mtime": os.path.getmtime(path), "token": res["access_token"],
                                    "exp": now + int(res.get("expires_in", 3600))})
    except (OSError, ValueError, TypeError):
        pass  # 캐시를 못 써도 이번 호출은 토큰으로 진행한다
    return res["access_token"]


def error_reason(body):
    """Google 오류 본문 → 원인 한 단어(SERVICE_DISABLED·PERMISSION_DENIED·invalid_grant 등)."""
    try:
        err = json.loads(body)
    except ValueError:
        return "SERVICE_DISABLED" if "not been used" in body or "is disabled" in body else ""
    if isinstance(err.get("error"), str):  # OAuth 토큰 오류: {"error":"invalid_grant", ...}
        return err["error"]
    e = err.get("error") or {}
    for d in e.get("details") or []:
        if isinstance(d, dict) and d.get("reason"):
            return d["reason"]
    msg = e.get("message") or ""
    if "has not been used" in msg or "is disabled" in msg:
        return "SERVICE_DISABLED"
    return e.get("status") or ""


def call(token, path, body=None):
    req = urllib.request.Request(f"{API}/{path}", method="POST" if body is not None else "GET",
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        raise GaError(f"HTTP {e.code}", f"HTTP {e.code}: {raw[:600]}", error_reason(raw))
    except (urllib.error.URLError, OSError) as e:
        raise GaError("HTTP 000", f"cannot reach {API}: {getattr(e, 'reason', e)}")


def parse_filter(expr):
    """'eventName==sign_up' | 'pagePath=~/interview'(포함) | 'platform^=Android'(시작) | 'country!=Japan', 쉼표 = AND"""
    exprs = []
    for part in expr.split(","):
        # 가장 앞에 나오는 연산자로 나눈다(값 안의 '=='·'=~' 는 값으로 둔다).
        hits = [(part.find(op), op, mt) for op, mt in FILTER_OPS if part.find(op) > 0]
        if not hits:
            raise GaError("bad filter", f"filter must be <field><op><value> with op == != =~ ^= : {part!r}")
        _, op, mt = min(hits)
        k, v = part.split(op, 1)
        f = {"filter": {"fieldName": k.strip(), "stringFilter": {"matchType": mt, "value": v.strip()}}}
        exprs.append({"notExpression": f} if op == "!=" else f)
    return exprs[0] if len(exprs) == 1 else {"andGroup": {"expressions": exprs}}


def order_by(order, metrics):
    desc = order.startswith("-")
    name = order.lstrip("-")
    kind = "metric" if any(m["name"] == name for m in metrics) else "dimension"
    return [{kind: {f"{kind}Name": name}, "desc": desc}]


def report_body(a):
    if a.end and not a.start:
        raise GaError("bad args", "--end needs --start (otherwise the last --days days are used)")
    mets = [{"name": x.strip()} for x in a.metrics.split(",") if x.strip()]
    dims = [{"name": x.strip()} for x in a.dims.split(",") if x.strip()]
    dr = {"startDate": a.start, "endDate": a.end or "today"} if a.start else {"startDate": f"{a.days}daysAgo", "endDate": "today"}
    body = {"dateRanges": [dr], "metrics": mets, "limit": a.limit, "metricAggregations": ["TOTAL"]}
    if dims:
        body["dimensions"] = dims
    if a.filter:
        body["dimensionFilter"] = parse_filter(a.filter)
    if a.order:
        body["orderBys"] = order_by(a.order, mets)
    elif dims and dims[0]["name"] in ("date", "dateHour"):
        body["orderBys"] = [{"dimension": {"dimensionName": dims[0]["name"]}}]
    return body


def realtime_body(a):
    body = {"metrics": [{"name": x.strip()} for x in a.metrics.split(",") if x.strip()], "limit": a.limit}
    dims = [{"name": x.strip()} for x in a.dims.split(",") if x.strip()]
    if dims:
        body["dimensions"] = dims
    if a.filter:
        body["dimensionFilter"] = parse_filter(a.filter)
    if a.order:
        body["orderBys"] = order_by(a.order, body["metrics"])
    return body


def print_table(r):
    dh = [h["name"] for h in r.get("dimensionHeaders", [])]
    mh = [h["name"] for h in r.get("metricHeaders", [])]
    rows = r.get("rows", [])
    print("\t".join(dh + mh))
    for row in rows:
        print("\t".join([d.get("value", "") for d in row.get("dimensionValues", [])] +
                        [m.get("value", "") for m in row.get("metricValues", [])]))
    print(f"-- {len(rows)} rows shown / {r.get('rowCount', len(rows))} total", file=sys.stderr)
    for t in r.get("totals", [])[:1]:
        print("TOTAL\t" + "\t".join(m.get("value", "") for m in t.get("metricValues", [])), file=sys.stderr)
    meta = r.get("metadata") or {}
    if meta.get("subjectToThresholding"):
        print("NOTE: subject to thresholding — rows with few users may be withheld", file=sys.stderr)
    if meta.get("samplingMetadatas"):
        print("NOTE: sampled result: " + json.dumps(meta["samplingMetadatas"]), file=sys.stderr)


def normalize_argv(argv):
    """'--order -activeUsers' 처럼 '-' 로 시작하는 값을 argparse 가 옵션으로 오인하지 않게 '--order=-activeUsers' 로 붙인다."""
    out, i = [], 0
    while i < len(argv):
        if argv[i] == "--order" and i + 1 < len(argv) and re.match(r"-[A-Za-z]", argv[i + 1]):
            out.append("--order=" + argv[i + 1])
            i += 2
            continue
        out.append(argv[i])
        i += 1
    return out


def parser():
    p = argparse.ArgumentParser(prog="ga.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("cmd", choices=["report", "realtime", "meta", "raw", "check", "aliases"])
    p.add_argument("arg", nargs="?")
    p.add_argument("--prop", default="", help="property alias (GA_PROPERTY_<ALIAS>); empty = GA_PROPERTY_ID")
    p.add_argument("--days", type=int, default=7)
    p.add_argument("--start")
    p.add_argument("--end")
    p.add_argument("--metrics", default="activeUsers")
    p.add_argument("--dims", default="")
    p.add_argument("--filter")
    p.add_argument("--order", help="metric or dimension name, '-' prefix = descending (e.g. --order -activeUsers)")
    p.add_argument("--limit", type=int, default=50)
    p.add_argument("--json", action="store_true", help="raw response (check: one JSON status line)")
    p.add_argument("--dry-run", action="store_true", help="print the request body without calling the API")
    return p


def run(a):
    if a.cmd == "aliases":
        try:
            kf = key_file()
            state = "ok"
        except GaError as e:
            kf, state = lookup("GA_KEY_FILE") or "", e.code
        for alias, prop in sorted(aliases().items()):
            print(f"{alias or '(default)'}\t{prop}")
        print(f"key file: {kf or '-'} ({state})", file=sys.stderr)
        return
    prop = property_id(a.prop)
    base = f"properties/{prop}"
    if a.cmd in ("report", "realtime", "raw"):
        if a.cmd == "raw":
            if not a.arg:
                raise GaError("bad args", "raw needs a runReport JSON body")
            try:
                body = json.loads(a.arg)
            except ValueError as e:
                raise GaError("bad args", f"raw body is not JSON: {e}")
        else:
            body = report_body(a) if a.cmd == "report" else realtime_body(a)
        if a.dry_run:
            print(json.dumps(body, ensure_ascii=False, indent=1))
            return
    path = key_file()
    sa = load_key(path)
    token = access_token(path, sa)
    if a.cmd == "check":
        m = call(token, f"{base}/metadata")
        res = {"ok": True, "property": prop, "as": sa["client_email"],
               "dimensions": len(m.get("dimensions", [])), "metrics": len(m.get("metrics", []))}
        if a.json:
            print(json.dumps(res))
        else:
            print(f"OK property {prop} as {sa['client_email']} · {res['dimensions']} dimensions · {res['metrics']} metrics")
        return
    if a.cmd == "meta":
        m = call(token, f"{base}/metadata")
        q = (a.arg or "").lower()
        for kind in ("dimensions", "metrics"):
            for x in m.get(kind, []):
                if not q or q in x["apiName"].lower() or q in x.get("uiName", "").lower():
                    print(f"{kind[:-1]}\t{x['apiName']}\t{x.get('uiName', '')}")
        return
    r = call(token, f"{base}:{'runRealtimeReport' if a.cmd == 'realtime' else 'runReport'}", body)
    if a.json:
        print(json.dumps(r, ensure_ascii=False, indent=1))
    else:
        print_table(r)


def main(argv=None):
    a = parser().parse_args(normalize_argv(sys.argv[1:] if argv is None else argv))
    try:
        run(a)
    except GaError as e:
        if a.cmd == "check" and a.json:
            print(json.dumps({"ok": False, "error": e.code, "reason": e.reason, "message": str(e)[:300]}))
            sys.exit(1)
        print(str(e) + (f" [{e.reason}]" if e.reason else ""), file=sys.stderr)
        sys.exit(1)
    except Exception as e:  # 예상 밖 응답(JSON 아님 등): check --json 은 한 줄 JSON 을 지킨다. 내용 대신 예외 종류만 낸다.
        if a.cmd == "check" and a.json:
            print(json.dumps({"ok": False, "error": "ga.py failed", "reason": type(e).__name__, "message": ""}))
            sys.exit(1)
        raise


if __name__ == "__main__":
    main()
