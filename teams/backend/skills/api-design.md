---
name: api-design
description: API 설명을 입력받아 RESTful API 설계 + Spring Boot Controller 코드 생성
team: backend
trigger: "api-design|API 설계|api|REST|컨트롤러"
---

# RESTful API 설계 Skill

## 사용법
/harness api-design [API 설명]

예시: `/harness api-design "지원자 목록 조회 API (페이징, 상태별 필터, 채용공고별 조회)"`
예시: `/harness api-design "면접 일정 등록 및 면접관 초대 API"`

## 실행 내용

입력받은 API 설명을 분석하여 RESTful 원칙에 따른 API 설계와 Spring Boot 구현 코드를 생성하라.

### API 설계 원칙
- URL: `/api/v1/{resource}` 형식, 복수형 명사 사용
- HTTP 메서드: GET(조회), POST(생성), PUT(전체 수정), PATCH(부분 수정), DELETE(삭제)
- 응답 포맷: `CommonResponse<T>` 래퍼 사용
- 페이징: Spring Data의 `Pageable` 사용 (`page`, `size`, `sort` 파라미터)
- 에러 응답: 표준 에러 코드 + 메시지 포맷

### ATS API 리소스 목록
| 리소스 | 기본 URL |
|--------|---------|
| 채용공고 | `/api/v1/job-postings` |
| 지원서 | `/api/v1/applications` |
| 지원자 | `/api/v1/applicants` |
| 면접 | `/api/v1/interviews` |
| 평가 | `/api/v1/evaluations` |
| 면접 일정 | `/api/v1/interview-schedules` |

---

## 출력 형식

### 1. API 명세 (OpenAPI 3.0 스타일)

```yaml
paths:
  /api/v1/{resource}:
    get:
      summary: 목록 조회
      tags: [ResourceName]
      parameters:
        - name: page
          in: query
          schema:
            type: integer
            default: 0
        - name: size
          in: query
          schema:
            type: integer
            default: 20
        - name: status
          in: query
          schema:
            type: string
            enum: [ACTIVE, CLOSED, DRAFT]
      responses:
        '200':
          description: 성공
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CommonResponse'
        '400':
          description: 잘못된 요청
        '401':
          description: 인증 필요
        '403':
          description: 권한 없음
```

### 2. Spring Boot Controller

```java
package com.company.ats.{domain}.controller;

import com.company.ats.{domain}.dto.*;
import com.company.ats.{domain}.service.{Resource}Service;
import com.company.ats.common.dto.CommonResponse;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.Parameter;
import io.swagger.v3.oas.annotations.responses.ApiResponse;
import io.swagger.v3.oas.annotations.responses.ApiResponses;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.web.PageableDefault;
import org.springframework.http.HttpStatus;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/{resources}")
@RequiredArgsConstructor
@Tag(name = "{Resource} API", description = "ATS {Resource} 관련 API")
public class {Resource}Controller {

    private final {Resource}Service {resource}Service;

    @GetMapping
    @Operation(summary = "{Resource} 목록 조회", description = "페이징, 필터링 지원")
    @ApiResponses({
        @ApiResponse(responseCode = "200", description = "조회 성공"),
        @ApiResponse(responseCode = "401", description = "인증 필요"),
    })
    @PreAuthorize("hasRole('RECRUITER') or hasRole('HR_MANAGER')")
    public CommonResponse<Page<{Resource}Response>> findAll(
        @PageableDefault(size = 20, sort = "createdAt,desc") Pageable pageable,
        @Parameter(description = "상태 필터") @RequestParam(required = false) String status
    ) {
        return CommonResponse.success({resource}Service.findAll(pageable, status));
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    @Operation(summary = "{Resource} 생성")
    @PreAuthorize("hasRole('RECRUITER')")
    public CommonResponse<{Resource}Response> create(
        @Valid @RequestBody {Resource}CreateRequest request
    ) {
        return CommonResponse.success({resource}Service.create(request));
    }

    @GetMapping("/{id}")
    @Operation(summary = "{Resource} 단건 조회")
    public CommonResponse<{Resource}Response> findById(
        @Parameter(description = "{Resource} ID") @PathVariable Long id
    ) {
        return CommonResponse.success({resource}Service.findById(id));
    }

    @PatchMapping("/{id}")
    @Operation(summary = "{Resource} 부분 수정")
    @PreAuthorize("hasRole('RECRUITER')")
    public CommonResponse<{Resource}Response> update(
        @PathVariable Long id,
        @Valid @RequestBody {Resource}UpdateRequest request
    ) {
        return CommonResponse.success({resource}Service.update(id, request));
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @Operation(summary = "{Resource} 삭제")
    @PreAuthorize("hasRole('RECRUITER') or hasRole('HR_MANAGER')")
    public void delete(@PathVariable Long id) {
        {resource}Service.delete(id);
    }
}
```

### 3. CommonResponse 표준 포맷

```json
{
  "success": true,
  "data": { },
  "error": null,
  "timestamp": "2024-01-15T14:30:00Z"
}
```

에러 응답:
```json
{
  "success": false,
  "data": null,
  "error": {
    "code": "ATS_001",
    "message": "요청한 리소스를 찾을 수 없습니다.",
    "field": null
  },
  "timestamp": "2024-01-15T14:30:00Z"
}
```
