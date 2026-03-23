---
name: entity
description: 엔티티명을 입력받아 JPA Entity + DTO + Repository + Service + Controller 생성
team: backend
trigger: "entity|엔티티|JPA|도메인 생성"
---

# JPA 엔티티 풀스택 생성 Skill

## 사용법
/harness entity [엔티티명] [선택: 필드 목록]

예시: `/harness entity Applicant`
예시: `/harness entity JobPosting "title:String, department:String, closingDate:LocalDate, status:JobPostingStatus"`

## 실행 내용

입력받은 엔티티명과 필드 정보를 바탕으로 ATS 표준 패키지 구조에 맞는 풀스택 코드를 생성하라.

### ATS 패키지 구조
```
com.company.ats.{domain}/
├── domain/
│   └── {EntityName}.java          (JPA Entity)
├── dto/
│   ├── {EntityName}Request.java   (입력 DTO)
│   └── {EntityName}Response.java  (출력 DTO)
├── repository/
│   └── {EntityName}Repository.java
├── service/
│   └── {EntityName}Service.java
└── controller/
    └── {EntityName}Controller.java
```

### ATS 핵심 엔티티 목록
- `Applicant`: 지원자 (이름, 이메일, 전화번호, 이력서URL, 지원상태)
- `JobPosting`: 채용공고 (제목, 부서, 위치, 마감일, 상태, 담당자)
- `Application`: 지원서 (지원자, 채용공고, 지원일, 현재단계, 첨부파일)
- `Interview`: 면접 (지원서, 일정, 유형, 장소, 면접관목록, 온라인여부)
- `Evaluation`: 평가 (면접, 면접관, 항목별점수, 총점, 등급, 코멘트)
- `InterviewSchedule`: 면접 일정 (면접관, 가능시간대, 예약상태)

---

## 생성 파일 1: {EntityName}.java

```java
package com.company.ats.{domain}.domain;

import jakarta.persistence.*;
import lombok.*;
import org.springframework.data.annotation.CreatedDate;
import org.springframework.data.annotation.LastModifiedDate;
import org.springframework.data.jpa.domain.support.AuditingEntityListener;

import java.time.LocalDateTime;

@Entity
@Table(name = "{table_name}")
@EntityListeners(AuditingEntityListener.class)
@Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
@AllArgsConstructor
@Builder
public class {EntityName} {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    // 도메인 필드

    @CreatedDate
    @Column(updatable = false)
    private LocalDateTime createdAt;

    @LastModifiedDate
    private LocalDateTime updatedAt;
}
```

## 생성 파일 2: {EntityName}Response.java

```java
package com.company.ats.{domain}.dto;

import com.company.ats.{domain}.domain.{EntityName};
import lombok.Builder;
import lombok.Getter;

import java.time.LocalDateTime;

@Getter
@Builder
public class {EntityName}Response {

    private Long id;
    // 응답 필드

    private LocalDateTime createdAt;
    private LocalDateTime updatedAt;

    public static {EntityName}Response from({EntityName} entity) {
        return {EntityName}Response.builder()
            .id(entity.getId())
            // 필드 매핑
            .createdAt(entity.getCreatedAt())
            .updatedAt(entity.getUpdatedAt())
            .build();
    }
}
```

## 생성 파일 3: {EntityName}Repository.java

```java
package com.company.ats.{domain}.repository;

import com.company.ats.{domain}.domain.{EntityName};
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Optional;

@Repository
public interface {EntityName}Repository extends JpaRepository<{EntityName}, Long> {
    // 도메인 특화 쿼리 메서드
}
```

## 생성 파일 4: {EntityName}Service.java

```java
package com.company.ats.{domain}.service;

import com.company.ats.{domain}.domain.{EntityName};
import com.company.ats.{domain}.dto.{EntityName}Request;
import com.company.ats.{domain}.dto.{EntityName}Response;
import com.company.ats.{domain}.repository.{EntityName}Repository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Service
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class {EntityName}Service {

    private final {EntityName}Repository {entityName}Repository;

    @Transactional
    public {EntityName}Response create({EntityName}Request request) {
        {EntityName} entity = // request to entity
        {EntityName} saved = {entityName}Repository.save(entity);
        return {EntityName}Response.from(saved);
    }

    public {EntityName}Response findById(Long id) {
        {EntityName} entity = {entityName}Repository.findById(id)
            .orElseThrow(() -> new EntityNotFoundException("{EntityName} not found: " + id));
        return {EntityName}Response.from(entity);
    }

    public List<{EntityName}Response> findAll() {
        return {entityName}Repository.findAll().stream()
            .map({EntityName}Response::from)
            .toList();
    }

    @Transactional
    public {EntityName}Response update(Long id, {EntityName}Request request) {
        {EntityName} entity = {entityName}Repository.findById(id)
            .orElseThrow(() -> new EntityNotFoundException("{EntityName} not found: " + id));
        // entity update logic
        return {EntityName}Response.from(entity);
    }

    @Transactional
    public void delete(Long id) {
        {entityName}Repository.deleteById(id);
    }
}
```

## 생성 파일 5: {EntityName}Controller.java

```java
package com.company.ats.{domain}.controller;

import com.company.ats.{domain}.dto.{EntityName}Request;
import com.company.ats.{domain}.dto.{EntityName}Response;
import com.company.ats.{domain}.service.{EntityName}Service;
import com.company.ats.common.dto.CommonResponse;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/v1/{domain-path}")
@RequiredArgsConstructor
@Tag(name = "{EntityName}", description = "{EntityName} 관련 API")
public class {EntityName}Controller {

    private final {EntityName}Service {entityName}Service;

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    @Operation(summary = "{EntityName} 생성")
    public CommonResponse<{EntityName}Response> create(@Valid @RequestBody {EntityName}Request request) {
        return CommonResponse.success({entityName}Service.create(request));
    }

    @GetMapping("/{id}")
    @Operation(summary = "{EntityName} 단건 조회")
    public CommonResponse<{EntityName}Response> findById(@PathVariable Long id) {
        return CommonResponse.success({entityName}Service.findById(id));
    }

    @GetMapping
    @Operation(summary = "{EntityName} 목록 조회")
    public CommonResponse<List<{EntityName}Response>> findAll() {
        return CommonResponse.success({entityName}Service.findAll());
    }

    @PutMapping("/{id}")
    @Operation(summary = "{EntityName} 수정")
    public CommonResponse<{EntityName}Response> update(
        @PathVariable Long id,
        @Valid @RequestBody {EntityName}Request request
    ) {
        return CommonResponse.success({entityName}Service.update(id, request));
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @Operation(summary = "{EntityName} 삭제")
    public void delete(@PathVariable Long id) {
        {entityName}Service.delete(id);
    }
}
```
