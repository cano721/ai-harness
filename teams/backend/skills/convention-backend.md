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

## 프로젝트 구조
> init 시 build.gradle/settings.gradle 분석으로 결정됨

결정할 것: 단일 모듈 vs 멀티 모듈

- 예시 A: 단일 모듈 (`src/main/java/...`)
- 예시 B: 멀티 모듈 (api + core + scheduler 등)

### 멀티 모듈 구조 (해당하는 경우)

결정할 것: 각 모듈의 역할

```
{project}/
├── {module-api}/          # API 서버 (Controller, Facade)
├── {module-core}/         # 핵심 도메인 (Entity, Repository, 공통)
└── {module-scheduler}/    # 스케줄러/배치
```

- 모듈 간 의존성 방향: core ← api, core ← scheduler (core가 공통)
- 새 기능 추가 시 어느 모듈에 넣어야 하는지 판단 기준 필요

## 패키지 구조
> init 시 소스 디렉토리 분석으로 결정됨

결정할 것: 베이스 패키지, 도메인별 하위 구조

- 예시 A: `{base}.{도메인}.controller / service / repository / dto / entity`
- 예시 B: `{base}.domain.{도메인}.controller / facade / model / service`
- 예시 C: `{base}.{도메인}.api / application / domain / infrastructure`

### model 하위 디렉토리 (예시 B 사용 시)

결정할 것: model 디렉토리 안의 분류 방식

- 예시 A: `model/` (한 디렉토리에 모든 DTO)
- 예시 B: `model/rq/`, `model/rs/`, `model/dto/`, `model/enums/` (용도별 분리)

### 코드 예시

```
{base}.domain.{도메인}/
├── paths/                   # API 경로 상수
│   └── {Entity}ApiPaths.java
├── controller/              # REST Controller
│   ├── {Entity}Controller.java
│   └── Find{Entity}Controller.java
├── facade/                  # Facade (Controller ↔ Service 중간 레이어)
│   ├── {Entity}Facade.java
│   └── Find{Entity}Facade.java
├── service/                 # 비즈니스 로직
│   ├── find/                # 조회 전용
│   │   └── Find{Entity}Service.java
│   └── execute/             # 생성/수정/삭제
│       └── {Entity}Service.java
├── model/                   # DTO/VO
│   ├── rq/                  # Request DTO
│   ├── rs/                  # Response DTO
│   ├── dto/                 # 내부 전달 DTO
│   └── enums/               # Enum
├── entity/                  # JPA Entity (또는 core 모듈)
├── repository/              # JPA Repository (또는 core 모듈)
└── exception/               # 도메인별 예외
```

## 레이어 구조
> init 시 클래스 의존성 분석으로 결정됨

결정할 것: Controller에서 비즈니스 로직까지의 호출 흐름

- 예시 A: Controller → Service → Repository
- 예시 B: Controller → Facade → Service → Repository
- 예시 C: Controller → UseCase → Service → Repository

### Facade 패턴 (예시 B 사용 시)

결정할 것: Facade의 역할, Controller/Service와의 분리 기준

- Facade = 여러 Service를 조합하는 레이어 (트랜잭션 경계)
- Controller는 Facade만 호출, Service를 직접 호출하지 않음
- Find용/Execute용 Facade를 분리하는 경우도 있음

```java
// Facade 예시 — 여러 Service를 조합
@Component
@RequiredArgsConstructor
public class {Entity}Facade {

    private final {Entity}Service service;
    private final NotificationService notificationService;

    @Transactional
    public {Entity}Rs create(Create{Entity}Rq request) {
        {Entity} entity = service.create(request);
        notificationService.notify(entity);
        return {Entity}Rs.from(entity);
    }
}

// Find 전용 Facade (조회 로직이 복잡한 경우 분리)
@Component
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class Find{Entity}Facade {

    private final Find{Entity}Service findService;

    public Page<{Entity}Rs> list(Pageable pageable) {
        return findService.list(pageable);
    }
}
```

### Service 하위 분리 (조회/실행 분리)

결정할 것: Service를 역할별로 분리할지

- 예시 A: 하나의 Service에 모든 메서드
- 예시 B: `find/` (조회), `execute/` (생성/수정/삭제) 패키지 분리

```java
// find/ — 조회 전용 (readOnly)
@Service
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class Find{Entity}Service {

    private final {Entity}Repository repository;

    public {Entity} getById(Long id) {
        return repository.findById(id)
            .orElseThrow(() -> new NotFound{Entity}Exception());
    }
}

// execute/ — 생성/수정/삭제
@Service
@RequiredArgsConstructor
public class {Entity}Service {

    private final {Entity}Repository repository;

    @Transactional
    public {Entity} create(Create{Entity}Rq request) {
        return repository.save(request.toEntity());
    }
}
```

### 코드 예시 (Service)

```java
// Service 예시
@Service
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class {Entity}Service {

    private final {Entity}Repository repository;

    @Transactional
    public {Entity}Response create(Create{Entity}Request request) {
        {Entity} entity = {Entity}.builder()
            .name(request.name())
            .build();
        return {Entity}Response.from(repository.save(entity));
    }

    public {Entity}Response getById(Long id) {
        {Entity} entity = repository.findById(id)
            .orElseThrow(() -> new BusinessException(ErrorCode.NOT_FOUND));
        return {Entity}Response.from(entity);
    }

    public Page<{Entity}Response> list(Pageable pageable) {
        return repository.findAll(pageable)
            .map({Entity}Response::from);
    }
}
```

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

### 코드 예시

```java
// Request DTO 예시
public record Create{Entity}Request(
    @NotBlank String name,
    @Email String email,
    @Size(max = 100) String description
) {}

// Response DTO 예시
public record {Entity}Response(
    Long id,
    String name,
    String email,
    LocalDateTime createdAt
) {
    public static {Entity}Response from({Entity} entity) {
        return new {Entity}Response(
            entity.getId(),
            entity.getName(),
            entity.getEmail(),
            entity.getCreatedAt()
        );
    }
}
```

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

### 코드 예시 (ApiPaths — 예시 B 사용 시)

```java
// 도메인별 API 경로 상수 클래스
@UtilityClass
public class {Entity}ApiPaths {
    public static final String {ENTITY}_V1 = "/api/v1/{entities}";
    public static final String {ENTITY}_DETAIL_V1 = "/api/v1/{entities}/{id}";
}

// Controller에서 사용
@RestController
@RequiredArgsConstructor
@RequestMapping({Entity}ApiPaths.{ENTITY}_V1)
@Tag(name = "{Entity} API")
public class {Entity}Controller {

    private final {Entity}Facade facade;

    @GetMapping
    public CommonResponse<Page<{Entity}Rs>> list(Pageable pageable) {
        return CommonResponse.ok(facade.list(pageable));
    }

    @GetMapping("/{id}")
    public CommonResponse<{Entity}Rs> getById(@PathVariable Long id) {
        return CommonResponse.ok(facade.getById(id));
    }

    @PostMapping
    public CommonResponse<{Entity}Rs> create(@Valid @RequestBody Create{Entity}Rq request) {
        return CommonResponse.ok(facade.create(request));
    }
}
```

### 응답 포맷
결정할 것: 공통 응답 래퍼 사용 여부

- 예시 A: 공통 응답 (`CommonResponse<T>` → `{ code, message, data }`)
- 예시 B: 직접 반환 (void 또는 도메인 객체 직접)
- 예시 C: `ResponseEntity<T>` 직접 사용

### 코드 예시 (응답 포맷)

```java
// 공통 응답 클래스 예시
public record CommonResponse<T>(
    int code,
    String message,
    T data
) {
    public static <T> CommonResponse<T> ok(T data) {
        return new CommonResponse<>(200, "success", data);
    }
    public static <T> CommonResponse<T> error(int code, String message) {
        return new CommonResponse<>(code, message, null);
    }
}
```

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

### 코드 예시 (Controller)

```java
// Controller 예시
@RestController
@RequiredArgsConstructor
@RequestMapping("/api/v1/{entities}")
@Tag(name = "{Entity} API")
public class {Entity}Controller {

    private final {Entity}Service service;

    @PostMapping
    @Operation(summary = "{Entity} 생성")
    public CommonResponse<{Entity}Response> create(
            @Valid @RequestBody Create{Entity}Request request) {
        return CommonResponse.ok(service.create(request));
    }

    @GetMapping("/{id}")
    @Operation(summary = "{Entity} 상세 조회")
    public CommonResponse<{Entity}Response> getById(@PathVariable Long id) {
        return CommonResponse.ok(service.getById(id));
    }

    @GetMapping
    @Operation(summary = "{Entity} 목록 조회")
    public CommonResponse<Page<{Entity}Response>> list(Pageable pageable) {
        return CommonResponse.ok(service.list(pageable));
    }
}
```

## Entity 규칙
> init 시 Entity 클래스 분석으로 결정됨

### 생성 패턴
결정할 것: 객체 생성 방식

- 예시 A: `@Builder` (생성자에 적용)
- 예시 B: 정적 팩토리 메서드 (`Entity.create(...)`)
- 예시 C: 생성자 직접 사용

### 코드 예시 (Entity)

```java
// Entity 예시
@Entity
@Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
@Table(name = "{entities}")
public class {Entity} extends BaseEntity {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, length = 100)
    private String name;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private {Entity}Status status;

    @Builder
    private {Entity}(String name, {Entity}Status status) {
        this.name = name;
        this.status = status;
    }

    // 비즈니스 메서드 (@Setter 대신)
    public void updateName(String name) {
        this.name = name;
    }
}
```

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

### 코드 예시

```java
// 커스텀 예외 예시
public class BusinessException extends RuntimeException {
    private final ErrorCode errorCode;

    public BusinessException(ErrorCode errorCode) {
        super(errorCode.getMessage());
        this.errorCode = errorCode;
    }
}

// 에러 코드 enum
public enum ErrorCode {
    NOT_FOUND(404, "리소스를 찾을 수 없습니다"),
    DUPLICATE(409, "이미 존재하는 리소스입니다"),
    INVALID_INPUT(400, "잘못된 입력입니다");

    private final int status;
    private final String message;
}

// ControllerAdvice 예시
@RestControllerAdvice
public class GlobalExceptionHandler {
    @ExceptionHandler(BusinessException.class)
    public ResponseEntity<CommonResponse<Void>> handleBusinessException(BusinessException e) {
        return ResponseEntity
            .status(e.getErrorCode().getStatus())
            .body(CommonResponse.error(e.getErrorCode().getStatus(), e.getMessage()));
    }
}
```

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

### 코드 예시

```java
// Service 단위 테스트 예시
@ExtendWith(MockitoExtension.class)
class {Entity}ServiceTest {

    @InjectMocks
    private {Entity}Service service;

    @Mock
    private {Entity}Repository repository;

    @Test
    @DisplayName("{Entity} 생성 성공")
    void create_success() {
        // given
        Create{Entity}Request request = new Create{Entity}Request("name", "email@test.com");
        {Entity} entity = {Entity}.builder().name("name").build();
        given(repository.save(any())).willReturn(entity);

        // when
        {Entity}Response result = service.create(request);

        // then
        assertThat(result.name()).isEqualTo("name");
        verify(repository).save(any());
    }
}

// Controller 통합 테스트 예시
@WebMvcTest({Entity}Controller.class)
class {Entity}ControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private {Entity}Service service;

    @Test
    @DisplayName("{Entity} 목록 조회 API")
    void list_success() throws Exception {
        mockMvc.perform(get("/api/v1/{entities}"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.code").value(200));
    }
}
```

## 보안
결정할 것: 인증/인가 방식

- 예시 A: JWT + `@AuthenticationPrincipal`
- 예시 B: Session 기반
- 예시 C: OAuth2
