# AI Harness - 설정 관리 & 업데이트

## 3가지 관리 축

| 축 | 설명 | 실행 |
|----|------|------|
| **버전 업데이트** | 회사 중앙 저장소에서 최신 규칙/Hook/스킬 받기 | `ai-harness update` |
| **로컬 설정 변경** | 프로젝트별 guardrail, Hook, 규칙 커스텀 | `ai-harness config` |
| **잠금 정책** | 회사가 강제하는 설정은 로컬에서 완화 불가 | `lock-policy.yaml` (설정 패키지 루트) |

## 잠금(Lock) 정책

| 수준 | 의미 | 예시 |
|------|------|------|
| **locked** | 절대 변경 불가 | 위험 명령 차단, 감사 로깅, 민감 정보 스캔 |
| **bounded** | 범위 내 조정 가능 | 테스트 커버리지 (최소 60%), 비용 한도 (최대 $20) |
| **free** | 자유 변경 | 팀별 Hook, 스킬, 워크플로우 |

## 설정 우선순위

```
회사 중앙 (global)       ← 기본값 제공
    ↓ 상속
팀 프로필 (teams/*)     ← 팀별 기본값
    ↓ 상속
프로젝트 로컬            ← 프로젝트별 커스텀
    ↓ 최종 적용

※ 보안 관련 설정은 프로젝트에서 완화 불가 (잠금 정책)
```

## CLI 명령어

```bash
ai-harness
├── init                          # 초기 설치
├── update                        # 중앙 저장소에서 최신 버전
├── config                        # 설정 관리 (show/set/reset/diff)
├── team                          # 팀 프로필 (list/add/remove/switch)
├── hook                          # Hook 관리 (list/enable/disable/test)
├── status                        # 현재 상태 요약
├── doctor                        # 설정 검증 + 진단
├── uninstall                     # 깔끔한 제거
└── version                       # 버전 정보
```
