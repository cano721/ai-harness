---
name: harness-scaffold
description: 프로젝트 컨벤션에 맞는 코드 보일러플레이트를 자동 생성합니다 — Service, Repository, Controller, 테스트 세트
---

<Purpose>
에이전트가 새 파일을 빈 상태에서 작성하지 않고,
프로젝트 컨벤션에 맞는 구조화된 보일러플레이트 위에서 작업하도록 돕습니다.
OpenAI의 "스캐폴딩이 코드보다 중요하다" 원칙을 적용합니다.
</Purpose>

<Use_When>
- "scaffold", "스캐폴딩", "보일러플레이트 생성"
- "새 엔티티 추가해줘", "CRUD 만들어줘"
- "Service 클래스 생성해줘"
</Use_When>

<Do_Not_Use_When>
- 기존 코드 수정 시 → 직접 Edit
- Entity/DTO만 필요할 때 → /entity 스킬 사용
</Do_Not_Use_When>

<Steps>
1. 컨벤션 로드:
   - .ai-harness/teams/{team}/skills/convention-{team}.md 를 Read
   - .ai-harness/config.yaml에서 project.base_package, project.entities 확인
   - 컨벤션이 없으면 "먼저 /harness-init을 실행하세요" 안내

2. 생성 대상 확인:
   - 사용자에게 생성할 엔티티/기능명 확인
   - 생성할 레이어 선택 (기본: 전체 세트)
     ```
     "다음 파일을 생성합니다:
      [1] Entity + Repository (데이터 레이어)
      [2] Service 인터페이스 + 구현체 (비즈니스 레이어)
      [3] Controller + DTO (API 레이어)
      [4] 테스트 (단위 + 통합)
      [5] 전체 세트 (1~4 모두)

      선택? (기본: 5)"
     ```

3. 컨벤션 기반 코드 생성:
   - 컨벤션에서 추출한 패턴 적용:
     - 패키지 구조: {base_package}.{layer}.{domain}
     - 네이밍: 컨벤션의 DTO 네이밍 패턴 (예: Create{Entity}Request)
     - 응답 클래스: 컨벤션의 공통 응답 클래스 사용
     - 예외 처리: 컨벤션의 커스텀 예외 클래스 사용
     - 테스트: 컨벤션의 테스트 프레임워크/패턴 사용

4. 각 레이어별 생성 규칙:

   **Entity + Repository:**
   ```java
   // 컨벤션의 기존 Entity 패턴 따름
   // @Entity, @Table, @Id 등 표준 JPA 어노테이션
   // Auditing 필드 포함 여부 → 컨벤션에서 확인
   ```

   **Service:**
   ```java
   // 인터페이스 + 구현체 분리 여부 → 컨벤션에서 확인
   // @Transactional 정책 → 컨벤션에서 확인
   // 예외 처리 → 컨벤션의 커스텀 예외 사용
   ```

   **Controller + DTO:**
   ```java
   // API 경로 패턴 → 컨벤션에서 확인 (/api/v1/{entities})
   // 응답 래핑 → 컨벤션의 공통 응답 클래스
   // Validation → 컨벤션의 검증 패턴
   ```

   **테스트:**
   ```java
   // 단위 테스트: Service 로직 (Mockito 등)
   // 통합 테스트: Controller (@WebMvcTest 또는 @SpringBootTest)
   // 테스트 데이터: 컨벤션의 Fixture/Factory 패턴
   ```

5. 아키텍처 검증:
   - 생성된 코드가 의존성 방향을 준수하는지 check-architecture 로직으로 사전 검증
   - Entity가 Service를 import하지 않는지 등 확인 후 생성

6. 출력:
   - 생성된 파일 목록과 위치 안내
   - "이 구조 위에서 비즈니스 로직을 구현하세요" 안내
   - 컨벤션과 다른 부분이 있으면 명시
</Steps>
