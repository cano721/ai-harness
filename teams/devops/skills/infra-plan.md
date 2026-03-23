---
name: infra-plan
description: Terraform 변경사항을 입력받아 plan 요약 + 영향 분석 (비용/다운타임/보안)
team: devops
trigger: "infra-plan|terraform|인프라|plan|IaC"
---

# Terraform Plan 분석 Skill

## 사용법
/harness infra-plan [Terraform plan 출력 또는 변경 파일 경로]

예시: `/harness infra-plan terraform/modules/ecs/main.tf`
예시: `/harness infra-plan` (실행 후 terraform plan 출력을 붙여넣기)

## 실행 내용

입력받은 Terraform 변경사항을 분석하여 인프라 변경의 영향도를 평가하고, 안전한 배포를 위한 분석 보고서를 생성하라.

### 분석 항목

**리소스 변경 분류**
- `(+) create`: 신규 생성 → 비용 증가, 즉시 효과
- `(~) update in-place`: 설정 변경 → 다운타임 가능성 검토
- `(-/+) replace`: 삭제 후 재생성 → **다운타임 발생 가능, 데이터 손실 위험**
- `(-) destroy`: 삭제 → **데이터 손실 위험**

---

## 출력 형식

### 변경 요약

| 구분 | 수량 | 리소스 목록 |
|------|------|-----------|
| 생성 (+) | N | [리소스명 목록] |
| 수정 (~) | N | [리소스명 목록] |
| 교체 (-/+) | N | [리소스명 목록] |
| 삭제 (-) | N | [리소스명 목록] |

### 위험 등급 평가

**🔴 Critical (즉시 중단 검토)**
- 데이터베이스 인스턴스 교체 (`aws_db_instance` replace)
- 프로덕션 VPC/서브넷 변경
- IAM 정책 대규모 변경

**🟠 High (배포 시간대 신중 검토)**
- ECS 서비스 재배포 (`aws_ecs_service` update)
- 로드밸런서 리스너 변경
- 보안 그룹 인바운드 규칙 변경

**🟡 Medium (일반 검토)**
- ECS Task Definition 업데이트
- Auto Scaling 설정 변경
- CloudWatch 알림 변경

**🟢 Low (안전)**
- 태그 변경
- IAM 태그 변경
- 모니터링 대시보드 변경

### 다운타임 분석

| 리소스 | 변경 유형 | 다운타임 예상 | 대안 |
|--------|---------|-------------|------|
| [리소스명] | replace | ~5분 | Blue/Green 배포 |
| [리소스명] | update | 없음 | - |

다운타임이 예상되는 경우:
- 예상 영향 시간:
- 영향 받는 서비스:
- 권장 배포 시간대: 서비스 트래픽 최저 시간대

### 비용 변경 예상

| 리소스 | 현재 월 비용 | 변경 후 예상 | 차이 |
|--------|-----------|-----------|------|
| [리소스명] | $X | $Y | +$Z |
| **합계** | $X | $Y | **+$Z** |

비용 증가 원인: [설명]

### 보안 그룹 변경 경고

보안 그룹 변경이 포함된 경우 다음을 반드시 검토하라:
- [ ] 새로 열리는 포트 및 허용 IP 대역 목적 확인
- [ ] 0.0.0.0/0 허용 규칙 추가 여부 (운영 환경 금지)
- [ ] 삭제되는 규칙이 현재 사용 중인지 확인
- [ ] 변경된 보안 그룹을 참조하는 다른 리소스 영향 확인

### 실행 권고사항

```bash
# 1. Plan 재확인
terraform plan -out=tfplan.bin

# 2. Plan 상세 보기
terraform show -json tfplan.bin | jq '.resource_changes[] | select(.change.actions[] | contains("delete", "create"))'

# 3. 적용 (충분한 검토 후)
terraform apply tfplan.bin

# 4. 상태 확인
terraform state list
```

### 승인 체크리스트
- [ ] 모든 Critical/High 항목 검토 완료
- [ ] 다운타임 발생 시 서비스 팀 사전 공지 완료
- [ ] 비용 증가분 예산 승인 완료 (월 $X 이상 시)
- [ ] 보안 그룹 변경 보안팀 검토 완료
- [ ] 롤백 방법 (`terraform apply` 이전 state) 확인 완료
