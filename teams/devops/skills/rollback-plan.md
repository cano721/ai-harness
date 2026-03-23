---
name: rollback-plan
description: 배포 정보를 입력받아 트래픽 전환/DB 롤백/캐시 무효화/알림 포함 롤백 계획 생성
team: devops
trigger: "rollback-plan|롤백|rollback|배포 실패|rollback plan"
---

# 롤백 계획 생성 Skill

## 사용법
/harness rollback-plan [배포 환경] [현재 버전] [롤백 목표 버전]

예시: `/harness rollback-plan production v1.5.0 v1.4.3`
예시: `/harness rollback-plan staging` (현재 배포 정보 자동 조회 시도)

## 실행 내용

입력받은 배포 정보를 바탕으로 즉시 실행 가능한 단계별 롤백 계획을 생성하라. 각 단계에는 실행 명령어와 검증 방법을 포함하라.

### 롤백 의사결정 기준
다음 중 하나 이상 해당 시 즉시 롤백 실행:
- 에러율 > 5% (5분 지속)
- P99 응답 시간 > 3초 (10분 지속)
- 핵심 기능 장애 (지원서 제출, 로그인 불가)
- DB 커넥션 풀 고갈
- OOM(Out Of Memory) 반복 발생

---

## 출력 형식: 롤백 실행 플레이북

**환경**: {environment}
**현재 버전 (문제)**: {current-version}
**롤백 목표 버전**: {rollback-version}
**롤백 결정 시각**: ___________
**롤백 실행자**: ___________
**예상 소요 시간**: ___________

---

### Phase 1: 트래픽 전환 (즉시, 목표: 2분 내)

**목적**: 사용자 트래픽을 안정 버전으로 즉시 전환

```bash
# 1-1. ECS 서비스 이전 버전으로 업데이트
aws ecs update-service \
  --cluster ats-{environment}-cluster \
  --service ats-api \
  --task-definition ats-api:{previous-task-def-revision} \
  --force-new-deployment

# 1-2. 배포 상태 모니터링
aws ecs wait services-stable \
  --cluster ats-{environment}-cluster \
  --services ats-api

# 1-3. Blue/Green 사용 시: 로드밸런서 타겟 그룹 전환
aws elbv2 modify-listener \
  --listener-arn {listener-arn} \
  --default-actions Type=forward,TargetGroupArn={stable-target-group-arn}
```

**검증**:
- [ ] `GET /actuator/health` → `{"status": "UP"}`
- [ ] 에러율 정상화 확인 (Datadog)
- [ ] 응답 시간 정상화 확인

---

### Phase 2: DB 롤백 여부 결정 (5분 내 결정)

**DB 롤백이 필요한 경우**:
- 이번 배포에 DB 마이그레이션이 포함된 경우
- 애플리케이션 롤백만으로 데이터 정합성이 깨지는 경우

```sql
-- DB 롤백 전 현재 상태 확인
SELECT version, installed_on, success
FROM flyway_schema_history
ORDER BY installed_rank DESC
LIMIT 5;
```

**DB 롤백 실행** (매우 신중하게):
```bash
# Flyway Undo 실행 (undo 스크립트가 준비된 경우)
./gradlew flywayUndo \
  -Dflyway.url={db-url} \
  -Dflyway.user={db-user} \
  -Dflyway.password={db-password}
```

**DB 롤백 불필요한 경우**: 이전 버전 앱이 새 스키마와 호환되면 생략 가능

- [ ] DB 롤백 필요 여부: ☐ 필요 / ☐ 불필요
- [ ] DB 롤백 실행 완료 (필요 시)
- [ ] 데이터 정합성 검증 완료

---

### Phase 3: 캐시 무효화 (5분 내)

```bash
# Redis 캐시 무효화 (영향 받는 키 패턴)
redis-cli -h {redis-host} -p 6379 \
  --scan --pattern "ats:*" | xargs redis-cli DEL

# 특정 패턴만 무효화 (더 안전)
redis-cli -h {redis-host} -p 6379 \
  --scan --pattern "ats:applicant:*" | xargs redis-cli DEL

# CDN 캐시 퍼지 (CloudFront)
aws cloudfront create-invalidation \
  --distribution-id {distribution-id} \
  --paths "/*"
```

- [ ] Redis 캐시 무효화 완료
- [ ] CDN 캐시 퍼지 완료 (정적 자산 변경 시)
- [ ] 캐시 워밍 실행 (필요 시)

---

### Phase 4: 알림 및 사후 처리

**즉시 알림** (롤백 결정 즉시):
```
[긴급] ATS {environment} 롤백 진행 중
- 현재 버전: {current-version}
- 롤백 버전: {rollback-version}
- 사유: {reason}
- 담당자: {name}
- ETA: {estimated-time}
```

**완료 알림** (롤백 완료 후):
```
[완료] ATS {environment} 롤백 완료
- 롤백 버전: {rollback-version}
- 소요 시간: {duration}
- 현재 상태: 정상
- 원인 분석: 진행 예정
```

- [ ] 개발팀 Teams/Slack 알림 발송
- [ ] CS팀 장애 공지 발송 (고객 영향 시)
- [ ] 장애 티켓 생성 (Jira)
- [ ] 사후 분석(Post-mortem) 일정 잡기 (24시간 내)

---

### 롤백 완료 검증

- [ ] 서비스 버전 확인: `GET /actuator/info` → `{rollback-version}`
- [ ] 핵심 기능 스모크 테스트 통과
- [ ] 에러율 < 1% 유지
- [ ] DB 데이터 정합성 확인
- [ ] 모니터링 알림 정상화

### 사후 분석 체크리스트
- [ ] 장애 타임라인 작성
- [ ] 근본 원인 분석 (RCA)
- [ ] 재발 방지 대책 수립
- [ ] 핫픽스 개발 일정 확정
