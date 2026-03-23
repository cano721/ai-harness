---
name: convention-backend
description: Backend 코드 컨벤션 — 패키지 구조, API 규칙, DTO 네이밍, 예시 코드
team: backend
trigger: "컨벤션|convention|코드 규칙|코딩 규칙"
---

# Backend 코드 컨벤션

## 기술 스택
- Spring Boot 3.x + Java 17 + JPA + Flyway

## 패키지 구조
```
com.company.ats.{도메인}.controller  — REST API
com.company.ats.{도메인}.service     — 비즈니스 로직
com.company.ats.{도메인}.repository  — JPA Repository
com.company.ats.{도메인}.dto         — Request/Response DTO
com.company.ats.{도메인}.entity      — JPA Entity
```

## DTO 네이밍
- `{Action}{Entity}Request` / `{Action}{Entity}Response`
- 예: `CreateApplicantRequest`, `GetApplicantResponse`

## API 규칙
- RESTful, 버저닝 필수: `/api/v1/...`
- 응답 포맷:
```json
{
  "code": 0,
  "message": "success",
  "data": {}
}
```
- 페이징: `Pageable` (page, size, sort)
- Swagger 어노테이션 필수 (`@Operation`, `@ApiResponse`)

## 예외 처리
- `BusinessException(code, message)` 사용
- `@ControllerAdvice`로 전역 처리
- HTTP 상태: 400 (요청 오류), 404 (미존재), 409 (충돌), 500 (서버 오류)

## 로깅
- `@Slf4j` 사용 (System.out 절대 금지)
- `log.info` (정상), `log.warn` (경고), `log.error` (에러)

## DB
- DDL 변경: Flyway 마이그레이션 (`V{timestamp}__{desc}.sql`)
- SQL 파라미터 바인딩 필수 (문자열 연결 금지)
- `SELECT *` 금지, 필요한 컬럼만 명시
- `@Transactional` 적절한 사용

## 아키텍처
- MSA: 서비스 간 REST + 이벤트 기반 통신
- 공통 모듈(common-lib) 우선 활용
- 캐시: Redis (TTL은 서비스별 판단)

## 예시: 지원자 목록 조회 API

```java
@RestController
@RequestMapping("/api/v1/applicants")
@RequiredArgsConstructor
@Slf4j
public class ApplicantController {

    private final ApplicantService applicantService;

    @Operation(summary = "지원자 목록 조회")
    @GetMapping
    public CommonResponse<Page<GetApplicantResponse>> getApplicants(Pageable pageable) {
        return CommonResponse.success(applicantService.getApplicants(pageable));
    }
}
```
