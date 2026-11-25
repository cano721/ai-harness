"""답변을 소리로 읽기 좋게 다듬고 나눈다."""
import re


def clean(text, wake_words=()):
    text = re.sub(r"```.*?```", " 코드 생략. ", text, flags=re.S)
    text = re.sub(r"^[ \t|:\-]+$", " ", text, flags=re.M)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"https?://\S+", "링크", text)
    text = re.sub(r"[`*_#>|]", " ", text)
    # 읽는 소리를 마이크가 다시 듣고 명령으로 처리하지 않게 호출어는 바꿔 읽는다.
    # "헤이 클로드"는 "클로드"로 읽는다. 뒷말만으로는 부른 것이 아니고 듣기에도 자연스럽다.
    keys = {re.sub(r"\W+", "", w.lower()) for w in wake_words}
    for wake in sorted(wake_words, key=len, reverse=True):
        tail = wake.split()[-1] if len(wake.split()) > 1 else ""
        spoken = tail if tail and re.sub(r"\W+", "", tail.lower()) not in keys else "호출어"
        text = re.sub(r"[\s\.,!\?]*".join(re.escape(ch) for ch in wake.replace(" ", "")), spoken, text, flags=re.I)
    return " ".join(text.split())


def chunk(text, start, limit):
    """start 부터 limit 자 안팎을 문장 끝에 맞춰 자른다. (조각, 다음 시작 위치)"""
    rest = text[start:]
    if len(rest) <= limit:
        return rest, len(text)
    cut = rest[:limit]
    end = max(cut.rfind(". "), cut.rfind("다. "), cut.rfind("? "), cut.rfind("! "))
    size = end + 1 if end > limit // 2 else limit
    return rest[:size].strip(), start + size
