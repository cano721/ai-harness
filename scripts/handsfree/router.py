"""받아쓴 문장을 동작으로 바꾼다. 입출력만 있고 부수 효과는 없다."""
import re
import unicodedata

SINO = {"일": 1, "이": 2, "삼": 3, "사": 4, "오": 5, "육": 6, "칠": 7, "팔": 8, "구": 9, "십": 10}
NATIVE = {"한": 1, "두": 2, "세": 3, "네": 4, "다섯": 5, "여섯": 6, "일곱": 7, "여덟": 8, "아홉": 9, "열": 10, "첫": 1}
NUM_WORDS = dict(SINO, **NATIVE)


def _alt(words):
    return "|".join(sorted(words, key=len, reverse=True))


NUM = r"(\d+|" + _alt(NUM_WORDS) + r")"
# 세션 번호에는 "이번 세션" "한번"처럼 일상어와 겹치는 "이" "한"을 쓰지 않는다.
SESSION_NUM = r"(\d+|" + _alt([w for w in NUM_WORDS if w not in ("이", "한")]) + r")"
# 선택지 번호는 좁게 받는다. "한번" "이번"은 일상어라 번호로 보지 않는다.
CHOICE = r"(?:(\d+)번|(" + _alt([w for w in SINO if w != "이"]) + r")번|" + NUM + r"번째(?:거|걸로|걸로해|걸로해줘|로|로해|로해줘)?|(\d+)번(?:선택|으로|으로해|으로해줘))"
SESSION_SUFFIX = r"(?:으로|로)?(?:가|가줘|가자|이동|이동해|이동해줘|전환|전환해|전환해줘|열어|열어줘|바꿔|바꿔줘)?"
PARTICLE = r"(?:에다가|에다|에게|한테|에)"
SEPARATORS = r"[\s\.,!\?]*"
LEADING = r"^[\s\.,!\?\-\"'“‘]*"
# 다른 세션을 가리켜 말할 수 있는 조작. 나머지는 현재 세션에만 한다.
TARGETABLE = ("approve", "approve_force", "deny", "interrupt", "explain_dialog", "read_last", "read_more", "read_all")


# 받아쓰기가 자주 헷갈리는 소리. 초성 ㄱㄲㅋ·ㄷㄸㅌ·ㅂㅃㅍ·ㅈㅉㅊ·ㅅㅆ, 중성 ㅐㅔ·ㅒㅖ·ㅙㅚㅞ, ㅢ→ㅣ, 단어 첫 ㅎ→ㅇ.
CHO_GROUPS = [{0, 1, 15}, {3, 4, 16}, {7, 8, 17}, {12, 13, 14}, {9, 10}]
JUNG_GROUPS = [{1, 5}, {3, 7}, {10, 11, 15}]
H, IEUNG, UI, I = 18, 11, 19, 20
# 소리 규칙으로 안 나오는 표기(영어·장음). 단어 통째로 바뀐다.
LOANWORDS = {"헤이": ["hey", "헤"], "클로드": ["claude", "클라우드", "클로우드"], "오케이": ["ok", "okay"],
             "자비스": ["jarvis"], "하이": ["hi"]}


def _syllable_alts(ch, word_start):
    code = ord(ch) - 0xAC00
    if not 0 <= code < 11172:
        return []
    cho, jung, jong = code // 588, code % 588 // 28, code % 28
    chos = sorted(next((g for g in CHO_GROUPS if cho in g), {cho}))
    jungs = sorted(next((g for g in JUNG_GROUPS if jung in g), {I} if jung == UI else {jung}) | {jung})
    # 초성과 중성 중 한쪽만 바꾼다. 둘 다 바꾸면 다른 말이 된다. 단어 첫 ㅎ이 빠지는 것("헤이"→"애이")만 함께 바뀐다.
    pairs = [(c, jung) for c in chos] + [(cho, j) for j in jungs]
    if word_start and cho == H:
        pairs += [(IEUNG, j) for j in jungs]
    alts = [chr(0xAC00 + c * 588 + j * 28 + jong) for c, j in pairs]
    return [s for s in dict.fromkeys(alts) if s != ch]


def _word_alts(word):
    alts = list(LOANWORDS.get(word, []))
    for i, ch in enumerate(word):
        alts += [word[:i] + s + word[i + 1:] for s in _syllable_alts(ch, i == 0)]
    return [a for a in dict.fromkeys(alts) if a != word]


def wake_variants(wake, limit=60):
    """호출어가 받아쓰기에서 달리 적힐 만한 모양. 한 단어만 바뀐 것을 먼저, 두 단어가 함께 바뀐 것을 뒤에 둔다.
    단어 안에서는 한 음절만 바꾼다. 여러 음절을 함께 바꾸면 전혀 다른 말이 되어 일상 대화에서 불린다."""
    words = wake.split()
    alts = [_word_alts(w) for w in words]
    shapes = [words[:i] + [a] + words[i + 1:] for i, options in enumerate(alts) for a in options]
    for i in range(len(words)):
        for j in range(i + 1, len(words)):
            for a in alts[i]:
                for b in alts[j]:
                    shape = list(words)
                    shape[i], shape[j] = a, b
                    shapes.append(shape)
    seen, result = {squash(wake)}, []
    for shape in shapes:
        text = " ".join(shape)
        if squash(text) not in seen:
            seen.add(squash(text))
            result.append(text)
    return result[:limit]


def squash(text):
    """비교용: 공백·문장부호를 없애고 소문자로."""
    text = unicodedata.normalize("NFC", text).lower()
    return re.sub(r"[\s\.,!\?~…\"'“”‘’\-·:;()\[\]]+", "", text)


def to_number(token):
    return int(token) if token.isdigit() else NUM_WORDS.get(token)


def wake_pattern(wake):
    """"헤이, 클로드" "헤이클로드"처럼 띄어쓰기·쉼표가 달라도 같은 호출어로 본다."""
    return SEPARATORS.join(re.escape(ch) for ch in squash(wake))


def strip_wake(text, wake_words):
    """호출어로 시작하면 (True, 나머지), 아니면 (False, 원문).

    호출어 바로 뒤에 글자가 이어지면("헤이 클로드는 좋더라") 부른 게 아니라 얘기한 것이다.
    """
    rest, woke = unicodedata.normalize("NFC", text).strip(), False
    wakes = sorted((w for w in wake_words if squash(w)), key=len, reverse=True)
    for _ in range(3):  # "헤이 클로드, 헤이 클로드 승인"처럼 거듭 불러도 한 번으로 본다
        for wake in wakes:
            m = re.match(LEADING + wake_pattern(wake) + r"[야아]?(?=[\s\.,!\?~]|$)", rest, flags=re.I)
            if m:
                rest, woke = rest[m.end():].strip(" .,!?~"), True
                break
        else:
            break
    return (True, rest) if woke else (False, text.strip())


def has_wake(text, wake_words):
    """문장 어디에든 호출어가 있는지. 읽어 주는 소리와 섞여 들어온 말에서 찾을 때 쓴다."""
    stripped = unicodedata.normalize("NFC", text)
    return any(re.search(wake_pattern(w), stripped, flags=re.I) for w in wake_words if squash(w))


def match_command(key, cfg):
    plain = key[:-1] if key.endswith("요") and len(key) > 2 else key
    for action, phrases in cfg["commands"].items():
        if any(squash(p) in (key, plain) for p in phrases):
            return action
    return None


def said(text, phrases):
    key = squash(text)
    plain = key[:-1] if key.endswith("요") and len(key) > 2 else key
    return any(squash(p) in (key, plain) for p in phrases)


def route(text, cfg, armed=False):
    """동작 dict 를 돌려준다. 명령으로 볼 수 없으면 {"type": "ignore"}.

    armed 는 호출어만 부른 뒤의 대기 중이라는 뜻이다. 그때 들어온 말에는 "armed": True 가 붙는다.
    """
    woke, rest = strip_wake(text, cfg["wake_words"])
    if not woke and not armed:
        return {"type": "ignore"}
    action = _route(rest, cfg)
    if not woke:
        action["armed"] = True
    return action


HERE_WORDS = {"이거", "이것", "지금거", "이작업", "작업", "여기", "현재세션", "이세션", "지금세션"}
GO = r"(?:가|가줘|가자|이동|이동해|이동해줘|전환|전환해|전환해줘|열어|열어줘|바꿔|바꿔줘)"


def _route_alias(rest, key, cfg):
    """사용자가 정한 세션 별명("결제에 ~", "결제 승인", "결제로 가")."""
    for alias in sorted(cfg.get("aliases", {}), key=lambda a: len(a), reverse=True):
        spoken = r"\s*".join(re.escape(ch) for ch in squash(alias))
        if not spoken:
            continue
        m = re.match(r"^" + spoken + r"\s*(?:세션)?\s*" + PARTICLE + r"\s+(.+)$", rest, flags=re.I)
        if m:
            return {"type": "prompt", "text": m.group(1).strip(), "alias": alias}
        m = re.match(r"^" + spoken + r"\s*(?:세션)?\s+(.+)$", rest, flags=re.I)
        if m:
            command = match_command(squash(m.group(1)), cfg)
            if command in TARGETABLE:
                return {"type": command, "spoken": m.group(1).strip(), "alias": alias}
        target = re.escape(squash(alias))
        if re.fullmatch(target + r"(?:세션(?:으로|로)?" + GO + r"?|(?:으로|로)" + GO + r"?)", key, flags=re.I):
            return {"type": "goto_session_named", "name": alias, "alias": alias, "spoken": rest}
    return None


def _route(rest, cfg):
    key = squash(rest)
    if not key:
        return {"type": "wake_only"}

    m = re.match(r"^(?:(?P<num>" + SESSION_NUM + r")\s*번\s*(?:세션)?|(?P<name>.{1,20}?)\s*(?:세션)?)?\s*(?:이|가|은|는)?\s*"
                 r"(?:끝나면|끝나거든|다\s*되면|완료되면|멈추면|승인\s*필요하면)\s*(?:나한테|나에게)?\s*"
                 r"(?:알려|말해|불러)\s*(?:줘|주세요|줄래|줘요)?$", rest.strip(" .,!?~"))
    if m:
        action = {"type": "notify_done", "spoken": rest}
        if m.group("num"):
            action["index"] = to_number(m.group("num"))
        elif m.group("name") and squash(m.group("name")) not in HERE_WORDS:
            name = m.group("name").strip()
            if name in cfg.get("aliases", {}):
                action["alias"] = name
            else:
                action["session_name"] = name
        return action

    m = re.fullmatch(NUM + r"분(?:만|간|동안)?(?:쉬어|쉬자|꺼|꺼둬|멈춰|듣지마|조용히해|조용)(?:줘|해줘)?", key)
    if m:
        return {"type": "pause", "minutes": to_number(m.group(1))}

    # "3번 세션 승인": 다른 세션의 창에 답한다. "3번 세션에 ~해 줘": 그 세션으로만 보낸다.
    m = re.match(r"^" + SESSION_NUM + r"\s*번\s*세션\s*" + PARTICLE + r"?\s+(.+)$", rest)
    if m:
        index, tail = to_number(m.group(1)), m.group(2).strip()
        command = match_command(squash(tail), cfg)
        if command in TARGETABLE:
            return {"type": command, "spoken": tail, "index": index}
        if re.match(r"^" + SESSION_NUM + r"\s*번\s*세션\s*" + PARTICLE + r"\s", rest):
            return {"type": "prompt", "text": tail, "index": index}
    action = _route_alias(rest, key, cfg)
    if action:
        return action

    m = re.match(r"^(.{2,}?)\s*세션\s*" + PARTICLE + r"\s+(.+)$", rest)
    if m:
        # 이름으로 가리킨 전송은 코드 얘기("로그인 세션에 ~")와 헷갈릴 수 있어 보내기 전에 되묻는다.
        return {"type": "prompt", "text": m.group(2).strip(), "session_name": m.group(1).strip(),
                "spoken": rest, "ask_first": True}

    for phrase, prompt in cfg.get("macros", {}).items():
        if squash(phrase) == key:
            return {"type": "prompt", "text": prompt, "macro": phrase}

    command = match_command(key, cfg)
    if command:
        return {"type": command, "spoken": rest}

    m = re.fullmatch(SESSION_NUM + r"번째?세션" + SESSION_SUFFIX, key)
    if m:
        return {"type": "goto_session", "index": to_number(m.group(1))}

    m = re.fullmatch(CHOICE, key)
    if m:
        return {"type": "choose", "number": to_number(next(g for g in m.groups() if g)), "spoken": rest}

    m = re.fullmatch(r"(.+?)세션" + SESSION_SUFFIX, key)
    if m:
        return {"type": "goto_session_named", "name": m.group(1), "spoken": rest}

    return {"type": "prompt", "text": rest}
