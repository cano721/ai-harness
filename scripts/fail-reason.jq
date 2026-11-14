# 무인 실행 로그의 결과 줄(type == "result")로 실패 이유를 가른다. harvest-auto·autofix-auto·보드가 같이 쓴다.
# 사용: jq -Rrn -L <scripts> 'include "fail-reason"; log_fail_reason' <log>
# 로그인 만료·인증 실패(auth_expired)는 사람이 다시 로그인하기 전까지 반드시 실패한다 — 실패 횟수에 넣지 않고
# 남은 실행을 멈춘다(#315). 실측 결과 줄: is_error true, terminal_reason "api_error", api_error 없음,
# result "Failed to authenticate: ... Run `claude auth login` ... or use `claude setup-token` ...".
# 문구 판정은 API 오류로 끝난 결과 줄에만 쓴다 — 작업 중 실패 보고에 같은 문구가 섞여도 로그인 만료로 오인하지 않게
# (오인하면 실패 횟수에 들지 않아 포기하지 않고 매 회차 남은 실행을 멈춘다). terminal_reason이 없는 이전 형식은 문구로 본다.
def auth_failure:
  (.api_error_status == 401)
  or ((.api_error // "") | tostring | test("auth"; "i"))
  or (((.terminal_reason // "api_error") == "api_error")
      and ((.result // "") | tostring
        | test("Failed to authenticate|claude auth login|setup-token|authentication_error|OAuth token (has )?expired|Invalid API key|Please run /login"; "i")));

def fail_reason:
  if . == null then empty
  elif .api_error == "usage_limit_reached" or .api_error_status == 429 then "usage_limit"
  elif .is_error == true and auth_failure then "auth_expired"
  elif .is_error == true then (.api_error // "agent_error")
  else empty end;

def log_fail_reason: [inputs | fromjson? | objects | select(.type == "result")] | last | fail_reason;
