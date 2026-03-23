# Backend Team - CLAUDE.md

## 도메인
ATS (Applicant Tracking System) 채용 관리 시스템

## 기술 스택

- Spring Boot 3.x
- Java 17
- JPA (Hibernate)
- Flyway (DB 마이그레이션)

## 패키지 구조

```
com.company.ats.{도메인}.controller
com.company.ats.{도메인}.service
com.company.ats.{도메인}.repository
com.company.ats.{도메인}.dto
com.company.ats.{도메인}.entity
```

## 주요 엔티티

- Applicant (지원자)
- JobPosting (채용공고)
- Interview (면접)
- Evaluation (평가)
- Offer (합격 통보)
- User (사용자)

## DTO 네이밍

```
{Action}{Entity}Request   // 요청
{Action}{Entity}Response  // 응답

예: CreateApplicantRequest, GetApplicantResponse
```

## API 규칙

- RESTful 설계
- 버저닝: `/api/v1/...`
- 페이징 파라미터: `page`, `size`, `sort` (Spring Pageable 사용)

### 공통 응답 형식

```json
{
  "code": 0,
  "message": "success",
  "data": {}
}
```

### 페이징 응답

```json
{
  "code": 0,
  "message": "success",
  "data": {
    "content": [],
    "totalElements": 100,
    "totalPages": 10,
    "page": 0,
    "size": 10
  }
}
```

## DB 마이그레이션

DDL 변경 시 Flyway 마이그레이션 파일 작성 필수:

```
src/main/resources/db/migration/V{버전}__{설명}.sql
예: V1__create_applicant_table.sql
```

## 보안

- SQL 파라미터 바인딩 필수 (문자열 연결로 쿼리 조합 금지)
- 민감 정보 로그 출력 금지

## 예외 처리

```java
// 비즈니스 예외
throw new BusinessException(ErrorCode.APPLICANT_NOT_FOUND, "지원자를 찾을 수 없습니다.");

// 전역 예외 처리
@ControllerAdvice
public class GlobalExceptionHandler { ... }
```

## 로깅

- `@Slf4j` 사용
- `System.out.println` 사용 금지

```java
@Slf4j
public class ApplicantService {
    public void process() {
        log.info("Processing applicant: {}", applicantId);
    }
}
```

## MSA 통신

- 서비스 간 동기 통신: REST
- 서비스 간 비동기 통신: 이벤트 기반 (도메인 이벤트)
- 외부 서비스 호출 시 타임아웃/재시도 정책 설정 필수
