# Context Map — {project.name}

> 이 파일은 에이전트를 위한 "지도"입니다.
> 전체 매뉴얼이 아닌 핵심 진입점과 패턴만 담습니다.
> `/harness-init` 시 자동 생성되며, 프로젝트 변경에 따라 갱신할 수 있습니다.

## 프로젝트 개요
- **이름**: {project.name}
- **도메인**: {project.domain}
- **기술 스택**: {project.tech_stack}
- **베이스 패키지**: {project.base_package}

## 핵심 진입점
| 용도 | 경로 | 설명 |
|------|------|------|
| API 정의 | `src/main/java/{base_package}/controller/` | REST Controller |
| 비즈니스 로직 | `src/main/java/{base_package}/service/` | Service 레이어 |
| 데이터 접근 | `src/main/java/{base_package}/repository/` | JPA Repository |
| 도메인 모델 | `src/main/java/{base_package}/entity/` | JPA Entity |
| 설정 | `src/main/resources/application.yml` | 앱 설정 |
| DB 마이그레이션 | `src/main/resources/db/migration/` | Flyway/Liquibase |
| 테스트 | `src/test/java/{base_package}/` | 단위/통합 테스트 |

## 의존성 방향
```
Entity/DTO → Config → Repository → Service → Controller
(하위)                                        (상위)
```
- 하위 레이어는 상위 레이어를 import하면 안 됩니다
- 의존성 역전이 필요하면 인터페이스를 하위 레이어에 정의하세요

## 주요 엔티티
| 엔티티 | 테이블 | 핵심 필드 | 관계 |
|--------|--------|-----------|------|
| {각 엔티티 분석 결과} | | | |

## 공통 패턴
- **응답 클래스**: {컨벤션에서 감지된 패턴}
- **예외 처리**: {컨벤션에서 감지된 패턴}
- **DTO 네이밍**: {컨벤션에서 감지된 패턴}
- **API 경로**: {컨벤션에서 감지된 패턴}

## 자주 수정하는 파일
> `git log --format='' --name-only | sort | uniq -c | sort -rn | head -10` 결과

| 빈도 | 파일 | 역할 |
|------|------|------|
| {git 분석 결과} | | |

## 외부 연동
| 서비스 | 용도 | 진입점 |
|--------|------|--------|
| {config에서 감지} | | |

---
> 이 지도로 충분하지 않으면 컨벤션 파일을 참고하세요:
> `.ai-harness/teams/{team}/skills/convention-{team}.md`
