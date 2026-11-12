"""세션의 마지막 답이 사람에게 묻고 끝났는지 본다(보드 '지금 할 일'의 '답 대기').

질문 도구(AskUserQuestion)를 쓰지 않고 본문으로 "…진행할까요?"처럼 묻고 쉬는 세션이 많아, 상태만 보면 '결과 확인'으로
가라앉는다. 오판을 줄이려고 마지막 답의 **마지막 문장 하나**만 본다 — 중간의 수사 의문문이나 인용한 질문은 무시한다.
사람이 그 뒤에 이미 답했는지는 work.sh가 시각으로 가린다(답한 뒤면 reply_tail을 싣지 않는다).
"""
import re

_MD = re.compile(r"[*_`#>]+|^\s*[-+]\s+|^\s*\d+[.)]\s+|\[([^\]]*)\]\([^)]*\)")
_SENT = re.compile(r"[^.!?。？！\n]+[.!?。？！]*")
# 한국어: 상대에게 고르기·확인·결정을 청하는 어미. 영어: 묻는 관용구.
_KO = re.compile(r"(할까요|을까요|ㄹ까요|까요|주세요|주시겠어요|주실래요|주시면|드릴까요|하시겠어요|원하시나요|원하세요|괜찮을까요|괜찮으세요|어떠세요|어떨까요|정해\s?주|골라\s?주|알려\s?주|확인해\s?주|말씀해\s?주|어떻게 할지|진행할지|할지 알려)")
_EN = re.compile(r"^(should i|shall i|do you want|would you like|want me to|let me know|which (one|option)|can you confirm|please confirm)", re.I)


def plain(text):
    """마크다운 기호를 걷어 낸 한 줄."""
    out = []
    for line in str(text or "").splitlines():
        line = _MD.sub(lambda m: m.group(1) or "", line).strip()
        if line:
            out.append(line)
    return " ".join(out).strip()


def last_sentence(text):
    lines = [l for l in str(text or "").splitlines() if l.strip()]
    if not lines:
        return ""
    sents = [s.strip() for s in _SENT.findall(plain(lines[-1])) if s.strip()]
    return sents[-1] if sents else ""


def pending_ask(reply_tail):
    """마지막 문장이 질문이면 그 문장(마크다운 제거, 160자 안), 아니면 None."""
    s = last_sentence(reply_tail)
    if not s or len(s) < 4:
        return None
    if s.endswith(("?", "？")) or _KO.search(s) or _EN.search(s):
        return s if len(s) <= 160 else s[:158] + "…"
    return None
