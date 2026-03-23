---
name: convention-backend
description: Backend 코드 컨벤션 — 패키지 구조, API 규칙, DTO 네이밍, 예시 코드 (도메인 무관)
team: backend
trigger: "컨벤션|convention|코드 규칙|코딩 규칙"
---

# Backend 코드 컨벤션

> 이 컨벤션은 도메인에 무관한 범용 규칙입니다.
> 프로젝트 도메인 정보(엔티티, 용어)는 `.ai-harness/config.yaml`의 `project` 섹션을 참고하세요.

## 기술 스택
- Spring Boot 3.x + Java 17+ + JPA + 마이그레이션 도구 (Flyway/Liquibase)

## 패키지 구조
```
{basePackage}.{도메인}.controller   — REST API
{basePackage}.{도메인}.service      — 비즈니스 로직 (인터페이스 + Impl)
{basePackage}.{도메인}.repository   — JPA Repository
{basePackage}.{도메인}.dto          — Request/Response DTO
{basePackage}.{도메인}.entity       — JPA Entity
{basePackage}.{도메인}.mapper       — Entity ↔ DTO 변환
{basePackage}.common.config        — 설정 클래스
{basePackage}.common.exception     — 예외 클래스
{basePackage}.common.response      — 공통 응답
```

## 네이밍 규칙

### DTO
- Request: `{Action}{Entity}Request` — `CreateUserRequest`, `UpdateJobPostingRequest`
- Response: `{Action}{Entity}Response` — `GetUserResponse`, `ListJobPostingResponse`
- Action 종류: Create, Update, Delete, Get, List, Search

### Service
- 인터페이스: `{Entity}Service`
- 구현체: `{Entity}ServiceImpl`
- 메서드: `create{Entity}`, `update{Entity}`, `delete{Entity}`, `get{Entity}`, `list{Entities}`

### Repository
- `{Entity}Repository extends JpaRepository<{Entity}, Long>`
- 커스텀 쿼리: `findBy{Field}`, `findAllBy{Condition}`

### Controller
- `{Entity}Controller`
- 클래스: `@RestController`, `@RequestMapping("/api/v1/{entities}")`
- 메서드: `@GetMapping`, `@PostMapping`, `@PutMapping`, `@DeleteMapping`

## API 규칙

### URL 설계
```
GET    /api/v1/{entities}          — 목록 조회
GET    /api/v1/{entities}/{id}     — 단건 조회
POST   /api/v1/{entities}          — 생성
PUT    /api/v1/{entities}/{id}     — 수정
DELETE /api/v1/{entities}/{id}     — 삭제
```
- 복수형 사용 (`/users`, `/job-postings`)
- 케밥 케이스 (`/job-postings`, NOT `/jobPostings`)
- 버저닝 필수: `/api/v1/...`

### 공통 응답 포맷
```java
public class CommonResponse<T> {
    private int code;        // 0: 성공, 음수: 에러 코드
    private String message;  // "success" 또는 에러 메시지
    private T data;          // 응답 데이터

    public static <T> CommonResponse<T> success(T data) {
        return new CommonResponse<>(0, "success", data);
    }

    public static CommonResponse<Void> error(int code, String message) {
        return new CommonResponse<>(code, message, null);
    }
}
```

### 페이징
```java
// 요청: ?page=0&size=20&sort=createdAt,desc
public CommonResponse<Page<ListUserResponse>> getUsers(Pageable pageable) { ... }
```

### Swagger
```java
@Operation(summary = "사용자 목록 조회", description = "페이징 지원")
@ApiResponse(responseCode = "200", description = "조회 성공")
@GetMapping
public CommonResponse<Page<ListUserResponse>> getUsers(Pageable pageable) { ... }
```

## Entity 규칙

```java
@Entity
@Table(name = "users")
@Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
public class User extends BaseEntity {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, length = 100)
    private String name;

    @Column(nullable = false, unique = true)
    private String email;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private UserStatus status;

    @Builder
    public User(String name, String email, UserStatus status) {
        this.name = name;
        this.email = email;
        this.status = status;
    }

    public void updateName(String name) {
        this.name = name;
    }
}
```

### BaseEntity (공통 필드)
```java
@MappedSuperclass
@Getter
@EntityListeners(AuditingEntityListener.class)
public abstract class BaseEntity {
    @CreatedDate
    private LocalDateTime createdAt;

    @LastModifiedDate
    private LocalDateTime updatedAt;
}
```

### 주의사항
- `@Setter` 금지 — 비즈니스 메서드로 상태 변경
- `@NoArgsConstructor(access = PROTECTED)` — JPA 필수이지만 외부 생성 방지
- `@Builder` — 생성자에 적용 (클래스에 적용 X)
- Enum은 `@Enumerated(EnumType.STRING)` 필수

## 검증 (Validation)

```java
public class CreateUserRequest {
    @NotBlank(message = "이름은 필수입니다")
    @Size(max = 100, message = "이름은 100자 이하입니다")
    private String name;

    @NotBlank(message = "이메일은 필수입니다")
    @Email(message = "이메일 형식이 아닙니다")
    private String email;
}
```

Controller에서:
```java
@PostMapping
public CommonResponse<CreateUserResponse> createUser(@Valid @RequestBody CreateUserRequest request) { ... }
```

## 예외 처리

### BusinessException
```java
public class BusinessException extends RuntimeException {
    private final int code;

    public BusinessException(int code, String message) {
        super(message);
        this.code = code;
    }
}

// 사용
throw new BusinessException(-1001, "이미 존재하는 이메일입니다");
```

### GlobalExceptionHandler
```java
@RestControllerAdvice
@Slf4j
public class GlobalExceptionHandler {

    @ExceptionHandler(BusinessException.class)
    public ResponseEntity<CommonResponse<Void>> handleBusiness(BusinessException e) {
        log.warn("Business error: {}", e.getMessage());
        return ResponseEntity.badRequest()
            .body(CommonResponse.error(e.getCode(), e.getMessage()));
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<CommonResponse<Void>> handleValidation(MethodArgumentNotValidException e) {
        String message = e.getBindingResult().getFieldErrors().stream()
            .map(f -> f.getField() + ": " + f.getDefaultMessage())
            .collect(Collectors.joining(", "));
        return ResponseEntity.badRequest()
            .body(CommonResponse.error(-400, message));
    }
}
```

### HTTP 상태 코드
| 상태 | 용도 |
|------|------|
| 200 | 조회/수정 성공 |
| 201 | 생성 성공 |
| 400 | 요청 오류 (검증 실패, 비즈니스 오류) |
| 404 | 리소스 미존재 |
| 409 | 충돌 (중복) |
| 500 | 서버 내부 오류 |

## 로깅

```java
@Slf4j
@Service
public class UserServiceImpl implements UserService {

    public CreateUserResponse createUser(CreateUserRequest request) {
        log.info("사용자 생성 요청: email={}", request.getEmail());
        // ...
        log.info("사용자 생성 완료: id={}", user.getId());
        return response;
    }
}
```

- `System.out.println` 절대 금지
- 민감 정보 로깅 금지 (비밀번호, 토큰 등)
- 로그 레벨: `info` (정상 흐름), `warn` (예외적 상황), `error` (시스템 오류)

## DB / SQL

- DDL 변경은 반드시 마이그레이션 스크립트로 (수동 ALTER 금지)
- SQL 파라미터 바인딩 필수 (문자열 연결로 SQL 만들기 금지)
- `SELECT *` 금지 — 필요한 컬럼만 명시
- `@Transactional` — 쓰기 작업에만 적용, 읽기는 `readOnly = true`
- N+1 문제 방지: `@EntityGraph` 또는 `fetch join` 사용

```java
// 좋은 예
@Query("SELECT u FROM User u JOIN FETCH u.department WHERE u.status = :status")
List<User> findByStatusWithDepartment(@Param("status") UserStatus status);

// 나쁜 예
@Query("SELECT * FROM users")  // SELECT * 금지
```

## 테스트

### 단위 테스트 (Service)
```java
@ExtendWith(MockitoExtension.class)
class UserServiceImplTest {

    @InjectMocks
    private UserServiceImpl userService;

    @Mock
    private UserRepository userRepository;

    @Test
    @DisplayName("사용자 생성 성공")
    void createUser_success() {
        // given
        CreateUserRequest request = new CreateUserRequest("홍길동", "hong@test.com");
        User user = User.builder().name("홍길동").email("hong@test.com").build();
        given(userRepository.save(any(User.class))).willReturn(user);

        // when
        CreateUserResponse response = userService.createUser(request);

        // then
        assertThat(response.getName()).isEqualTo("홍길동");
        verify(userRepository).save(any(User.class));
    }
}
```

### 통합 테스트 (Controller)
```java
@SpringBootTest
@AutoConfigureMockMvc
class UserControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    @DisplayName("사용자 목록 조회 API")
    void getUsers() throws Exception {
        mockMvc.perform(get("/api/v1/users")
                .param("page", "0")
                .param("size", "20"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.code").value(0))
            .andExpect(jsonPath("$.data.content").isArray());
    }
}
```

### 테스트 네이밍
- `@DisplayName("한글로 시나리오 설명")`
- 메서드: `{메서드명}_{시나리오}` — `createUser_success`, `createUser_duplicateEmail`

### 테스트 구조
- Given-When-Then 패턴
- 커버리지 목표: 80% 이상

## 전체 예시: CRUD API

```java
// --- Controller ---
@RestController
@RequestMapping("/api/v1/users")
@RequiredArgsConstructor
@Slf4j
public class UserController {

    private final UserService userService;

    @Operation(summary = "사용자 목록 조회")
    @GetMapping
    public CommonResponse<Page<ListUserResponse>> getUsers(Pageable pageable) {
        return CommonResponse.success(userService.getUsers(pageable));
    }

    @Operation(summary = "사용자 단건 조회")
    @GetMapping("/{id}")
    public CommonResponse<GetUserResponse> getUser(@PathVariable Long id) {
        return CommonResponse.success(userService.getUser(id));
    }

    @Operation(summary = "사용자 생성")
    @PostMapping
    public ResponseEntity<CommonResponse<CreateUserResponse>> createUser(
            @Valid @RequestBody CreateUserRequest request) {
        CreateUserResponse response = userService.createUser(request);
        return ResponseEntity.status(HttpStatus.CREATED)
            .body(CommonResponse.success(response));
    }

    @Operation(summary = "사용자 수정")
    @PutMapping("/{id}")
    public CommonResponse<UpdateUserResponse> updateUser(
            @PathVariable Long id,
            @Valid @RequestBody UpdateUserRequest request) {
        return CommonResponse.success(userService.updateUser(id, request));
    }

    @Operation(summary = "사용자 삭제")
    @DeleteMapping("/{id}")
    public CommonResponse<Void> deleteUser(@PathVariable Long id) {
        userService.deleteUser(id);
        return CommonResponse.success(null);
    }
}

// --- Service ---
@Service
@RequiredArgsConstructor
@Slf4j
public class UserServiceImpl implements UserService {

    private final UserRepository userRepository;

    @Override
    @Transactional(readOnly = true)
    public Page<ListUserResponse> getUsers(Pageable pageable) {
        return userRepository.findAll(pageable)
            .map(ListUserResponse::from);
    }

    @Override
    @Transactional(readOnly = true)
    public GetUserResponse getUser(Long id) {
        User user = userRepository.findById(id)
            .orElseThrow(() -> new BusinessException(-1001, "사용자를 찾을 수 없습니다"));
        return GetUserResponse.from(user);
    }

    @Override
    @Transactional
    public CreateUserResponse createUser(CreateUserRequest request) {
        if (userRepository.existsByEmail(request.getEmail())) {
            throw new BusinessException(-1002, "이미 존재하는 이메일입니다");
        }
        User user = User.builder()
            .name(request.getName())
            .email(request.getEmail())
            .status(UserStatus.ACTIVE)
            .build();
        User saved = userRepository.save(user);
        log.info("사용자 생성 완료: id={}", saved.getId());
        return CreateUserResponse.from(saved);
    }
}
```
