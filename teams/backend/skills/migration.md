---
name: migration
description: DDL 변경 설명을 입력받아 Flyway 마이그레이션 스크립트 + 롤백 스크립트 생성
team: backend
trigger: "migration|마이그레이션|flyway|DDL|스키마 변경"
---

# Flyway 마이그레이션 스크립트 생성 Skill

## 사용법
/harness migration [DDL 변경 설명]

예시: `/harness migration "applicants 테이블에 linkedin_url varchar(500) 컬럼 추가"`
예시: `/harness migration "interviews 테이블의 location을 nullable로 변경하고 online_link 컬럼 추가"`

## 실행 내용

입력받은 DDL 변경 설명을 분석하여 Flyway 표준에 맞는 마이그레이션 스크립트와 롤백 스크립트를 생성하라.

### 네이밍 규칙
- 형식: `V{yyyyMMddHHmmss}__{description}.sql`
- 타임스탬프: 현재 시각 기준으로 생성
- description: 영문 snake_case, 변경 내용을 명확하게 표현
- 예시: `V20240115143000__add_linkedin_url_to_applicants.sql`

### Flyway 파일 위치
```
src/main/resources/db/migration/
├── V20240115143000__add_linkedin_url_to_applicants.sql  (마이그레이션)
└── U20240115143000__add_linkedin_url_to_applicants.sql  (언두/롤백)
```

### ATS 테이블 목록
| 테이블명 | 설명 |
|---------|------|
| `applicants` | 지원자 기본 정보 |
| `job_postings` | 채용공고 |
| `applications` | 지원서 (지원자 ↔ 채용공고) |
| `interviews` | 면접 정보 |
| `interview_schedules` | 면접관 가용 시간 |
| `evaluations` | 면접 평가 |
| `evaluation_items` | 평가 항목별 점수 |
| `attachments` | 첨부파일 (이력서 등) |

---

## 출력 파일 1: V{timestamp}__{description}.sql (마이그레이션)

```sql
-- Migration: {변경 설명}
-- Author: ATS Team
-- Date: {날짜}

-- 변경 전 상태 확인 (주석으로 현재 상태 기록)
-- ALTER TABLE {table_name} ...;

-- 메인 DDL
ALTER TABLE {table_name}
    ADD COLUMN {column_name} {data_type} {constraints};

-- 인덱스 (필요한 경우)
CREATE INDEX idx_{table_name}_{column_name}
    ON {table_name} ({column_name});

-- 기존 데이터 마이그레이션 (필요한 경우)
UPDATE {table_name}
SET {column_name} = {default_value}
WHERE {column_name} IS NULL;

-- 마이그레이션 완료 확인 쿼리 (주석)
-- SELECT COUNT(*) FROM {table_name} WHERE {column_name} IS NULL;
```

## 출력 파일 2: U{timestamp}__{description}.sql (롤백)

```sql
-- Rollback: {변경 설명} 롤백
-- Author: ATS Team
-- Date: {날짜}
-- CAUTION: 이 스크립트는 데이터 손실을 유발할 수 있습니다.

-- 인덱스 제거 (마이그레이션과 역순)
DROP INDEX IF EXISTS idx_{table_name}_{column_name};

-- DDL 롤백
ALTER TABLE {table_name}
    DROP COLUMN IF EXISTS {column_name};
```

## 체크리스트

생성 전 다음 사항을 확인하라:
- [ ] 타임스탬프가 기존 버전과 중복되지 않는가
- [ ] 롤백 시 데이터 손실이 발생하는가 (경고 주석 추가)
- [ ] 대용량 테이블 변경 시 락(Lock) 발생 위험이 있는가
- [ ] 외래키 제약 변경 시 참조 무결성 영향을 파악했는가
- [ ] NOT NULL 컬럼 추가 시 기존 데이터 처리 방안을 포함했는가
- [ ] 인덱스 생성/삭제가 포함되었는가

## 주의사항
- 운영 환경에서 실행 전 반드시 스테이징 환경에서 검증하라
- 대용량 테이블(100만 건 이상)의 경우 `pt-online-schema-change` 사용을 검토하라
- 마이그레이션 실행 중 롤백은 불가능하므로 신중하게 검토하라
