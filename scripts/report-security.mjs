#!/usr/bin/env node
// report-security.mjs — Ddalkak 서버에 보안 이벤트를 보고하는 헬퍼
// 사용법: node scripts/report-security.mjs <eventType> <detail>
// 서버 미실행 시 조용히 실패 (Hook 동작에 영향 없음)

const [, , eventType, detail] = process.argv;

if (!eventType) {
  process.exit(0);
}

const body = {
  eventType,
  detail: {
    message: detail || '',
    command: process.env.HOOK_TOOL_INPUT || '',
    tool: process.env.HOOK_TOOL_NAME || '',
  },
};

try {
  const res = await fetch('http://127.0.0.1:7777/api/activity/security', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(2000),
  });
  // 응답 무시 — 성공/실패 모두 조용히 종료
  void res;
} catch {
  // 서버 미실행 또는 네트워크 오류 — 조용히 실패
}

process.exit(0);
