---
name: convention-backend
description: Backend 코드 컨벤션 템플릿 — init 시 프로젝트 분석으로 실제 값이 채워짐
team: backend
trigger: "컨벤션|convention|코드 규칙|코딩 규칙"
---

# Backend 코드 컨벤션 (템플릿)

> 이 파일은 **범용 템플릿**입니다. `/harness-init` 실행 시 Claude가 프로젝트를 분석하여
> `.ai-harness/teams/backend/skills/convention-backend.md`에 프로젝트 맞춤 컨벤션을 생성합니다.
> 각 항목의 "결정할 것"이 실제 프로젝트 패턴으로 채워집니다.

## 기술 스택
> init 시 build.gradle/pom.xml 분석으로 결정됨

- Spring Boot 버전
- Java 버전
- ORM (JPA, MyBatis 등)
- 마이그레이션 도구 (Flyway, Liquibase 등)

## 패키지 구조
> init 시 소스 디렉토리 분석으로 결정됨

결정할 것: 베이스 패키지, 도메인별 하위 구조

- 예시 A: `{base}.{도메인}.controller / service / repository / dto / entity`
- 예시 B: `{base}.domain.{도메인}.controller / facade / model / service`
- 예시 C: `{base}.{도메인}.api / application / domain / infrastructure`

## 레이어 구조
> init 시 클래스 의존성 분석으로 결정됨

결정할 것: Controller에서 비즈니스 로직까지의 호출 흐름

- 예시 A: Controller → Service → Repository
- 예시 B: Controller → Facade → Service → Repository
- 예시 C: Controller → UseCase → Service → Repository

## DTO 네이밍
> init 시 기존 DTO 파일명 분석으로 결정됨

결정할 것: Request/Response 접미사 패턴, 내부 전달 객체 네이밍

- 예시 A: `{Action}{Entity}Request` / `{Action}{Entity}Response`
- 예시 B: `{Action}{Entity}Rq` / `{Action}{Entity}Rs`
- 예시 C: `{Entity}{Action}Dto`

결정할 것: DTO 디렉토리 구조

- 예시 A: `dto/` (한 디렉토리)
- 예시 B: `rq/`, `rs/`, `dto/` (용도별 분리)
- 예시 C: `model/request/`, `model/response/`

## API 규칙
> init 시 Controller 클래스 분석으로 결정됨

### URL 설계
결정할 것: 버저닝, 경로 패턴

- 버저닝: `/api/v1/...` (필수)
- 복수형 vs 단수형: `/users` vs `/user`
- 케밥 케이스 vs 카멜: `/job-postings` vs `/jobPostings`

### API 경로 관리
결정할 것: 경로 정의 방식

- 예시 A: Controller에 직접 문자열 (`@GetMapping("/api/v1/users")`)
- 예시 B: ApiPaths 상수 클래스 분리 (`@GetMapping(UserApiPaths.USERS_V1)`)

### 응답 포맷
결정할 것: 공통 응답 래퍼 사용 여부

- 예시 A: 공통 응답 (`CommonResponse<T>` → `{ code, message, data }`)
- 예시 B: 직접 반환 (void 또는 도메인 객체 직접)
- 예시 C: `ResponseEntity<T>` 직접 사용

### 페이징
결정할 것: 페이징 방식

- 예시 A: `Pageable` (page, size, sort)
- 예시 B: 커스텀 페이징 DTO
- 예시 C: Cursor 기반

### API 문서화
결정할 것: Swagger 어노테이션 수준

- `@Tag` (컨트롤러 레벨)
- `@Operation` (메서드 레벨)
- `@Schema` (DTO 필드 레벨)

## Entity 규칙
> init 시 Entity 클래스 분석으로 결정됨

### 생성 패턴
결정할 것: 객체 생성 방식

- 예시 A: `@Builder` (생성자에 적용)
- 예시 B: 정적 팩토리 메서드 (`Entity.create(...)`)
- 예시 C: 생성자 직접 사용

### 필수 어노테이션
- `@Entity`, `@Getter`
- `@NoArgsConstructor(access = AccessLevel.PROTECTED)` — JPA 필수
- `@Setter` 금지 — 비즈니스 메서드로 상태 변경

### 공통 필드
결정할 것: BaseEntity 사용 여부

- 예시 A: `BaseEntity` 상속 (createdAt, updatedAt)
- 예시 B: `@EntityListeners` 직접 사용
- 예시 C: 공통 필드 없음

### Enum 처리
- `@Enumerated(EnumType.STRING)` 필수 (ORDINAL 금지)

## 예외 처리
> init 시 예외 클래스 분석으로 결정됨

결정할 것: 예외 클래스 구조

- 예시 A: `BusinessException(code, message)` + `@ControllerAdvice`
- 예시 B: `CustomException(HttpStatus, message)` + 도메인별 예외 상속
- 예시 C: Spring 표준 예외 (`ResponseStatusException`)

결정할 것: 도메인별 예외 네이밍

- 예시 A: `{상황}{Entity}Exception` → `NotFoundMemberException`
- 예시 B: `{Entity}{상황}Exception` → `MemberNotFoundException`

## 로깅
- `@Slf4j` 사용 (System.out 절대 금지)
- `log.info` (정상 흐름), `log.warn` (예외적 상황), `log.error` (시스템 오류)
- 민감 정보 로깅 금지 (비밀번호, 토큰 등)

## DB / SQL
- DDL 변경은 반드시 마이그레이션 스크립트로 (수동 ALTER 금지)
- SQL 파라미터 바인딩 필수 (문자열 연결 금지)
- `SELECT *` 금지 — 필요한 컬럼만 명시
- N+1 방지: `@EntityGraph` 또는 `fetch join` 사용

결정할 것: 트랜잭션 정책

- 예시 A: `@Transactional` 쓰기만, 읽기는 `readOnly = true`
- 예시 B: Facade 레벨에서 트랜잭션 관리
- 예시 C: Service 레벨에서 트랜잭션 관리

## 검증 (Validation)
- `@Valid` + `@Validated` 사용
- Rq/Request DTO에 `@NotBlank`, `@NotNull`, `@Size`, `@Email` 등

## 테스트
> init 시 테스트 디렉토리 분석으로 결정됨

결정할 것: 테스트 프레임워크, 구조

- JUnit 5 + Mockito (단위)
- `@SpringBootTest` + `MockMvc` (통합)
- Given-When-Then 패턴
- `@DisplayName("한글 시나리오 설명")` 권장
- 커버리지 목표: __%

## 보안
결정할 것: 인증/인가 방식

- 예시 A: JWT + `@AuthenticationPrincipal`
- 예시 B: Session 기반
- 예시 C: OAuth2
