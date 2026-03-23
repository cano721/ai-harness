# DevOps Team - CLAUDE.md

## 도메인
ATS (Applicant Tracking System) 채용 관리 시스템

## 인프라 원칙

- IaC 필수: 모든 인프라는 코드로 관리
- 수동 인프라 변경 금지 (콘솔 직접 수정 금지)
- 시크릿 하드코딩 금지

## IaC 도구

| 레이어 | 도구 |
|--------|------|
| AWS 인프라 | Terraform |
| K8s 배포 | Helm |

### Terraform 변경 절차

```
terraform plan → 팀 리뷰/승인 → terraform apply
```

plan 결과 리뷰 없이 apply 금지.

## 시크릿 관리

- AWS Secrets Manager 사용
- `.env` 파일 저장소 커밋 금지
- 애플리케이션 코드 내 시크릿 하드코딩 금지
- 키 로테이션 정책 적용

## ATS 인프라 구성

| 컴포넌트 | 서비스 | 용도 |
|----------|--------|------|
| 컨테이너 오케스트레이션 | Amazon EKS | 애플리케이션 실행 |
| 데이터베이스 | RDS (PostgreSQL) | 메인 DB |
| 캐시 | ElastiCache (Redis) | 세션/캐시 |
| 파일 저장 | S3 | 이력서/첨부파일 |

## CI/CD 파이프라인

GitHub Actions 기반:

```
코드 푸시
  → 빌드
  → 테스트
  → 스테이징 배포
  → 승인
  → 프로덕션 배포
```

## 배포 전략

- **Blue-Green**: 다운타임 없는 전환, 즉시 롤백 가능
- **Canary**: 단계적 트래픽 전환 (5% → 25% → 100%)

## 모니터링

- **플랫폼**: Datadog
- **수집 대상**: APM, 로그, 메트릭, 트레이싱

### 알림 체계

```
Datadog 알럿 → PagerDuty (온콜) → Slack 채널
```

## SLA

| 지표 | 목표 |
|------|------|
| API 응답 p99 | < 500ms |
| 서비스 가용성 | 99.9% |

SLA 위반 시 즉시 PagerDuty 알럿 발송.

## 장애 대응

- Runbook: 주요 장애 유형별 대응 절차 문서화
- 포스트모템: 장애 종료 후 48시간 내 작성
- RCA(근본 원인 분석) 필수 포함
