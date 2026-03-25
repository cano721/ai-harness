---
name: agent-map
description: AI 에이전트 아키텍처 문서 자동 생성 — 코드베이스에서 에이전트/도구 구조를 분석하여 MD 산출물 생성
team: backend
trigger: "agent-map|에이전트 맵|에이전트 구조|에이전트 아키텍처|agent map|agent architecture"
---

<Purpose>
프로젝트의 AI 에이전트 코드베이스를 자동으로 분석하여,
에이전트 계층 구조, 도구 매핑, 모델 정보를 포함한 아키텍처 문서(MD)를 생성합니다.

에이전트 기반 시스템을 운영하는 팀이 구조를 파악하고 공유할 때,
매번 수동으로 정리하지 않고 코드에서 직접 뽑아낼 수 있습니다.
</Purpose>

<Use_When>
- "에이전트 구조 정리해줘", "에이전트 맵 만들어줘", "agent map"
- "에이전트 아키텍처 문서 생성해줘"
- 에이전트 구조를 MD 파일로 산출물 뽑아야 할 때
- 새 에이전트/도구 추가 후 문서를 갱신하고 싶을 때
</Use_When>

<Do_Not_Use_When>
- 에이전트 코드를 수정하거나 리팩토링할 때 (이 스킬은 읽기 전용)
- 단일 에이전트의 프롬프트만 확인하고 싶을 때 → 해당 파일 직접 Read
</Do_Not_Use_When>

<Steps>
1. 기술 스택 자동 감지
   - 프로젝트 루트에서 빌드/의존성 파일을 탐색하여 에이전트 프레임워크를 판별한다.
   - 감지 순서:

   **1-1. Java/Kotlin 프로젝트**
   - Glob: `**/build.gradle*`, `**/pom.xml`
   - 빌드 파일 내에서 Grep으로 의존성 확인:
     - `spring-ai` → **Spring AI** 프리셋
     - `langchain4j` → **LangChain4j** 프리셋
   - 프리셋 없이 빌드 파일만 존재 → **Java Generic** 프리셋

   **1-2. Python 프로젝트**
   - Glob: `**/requirements.txt`, `**/pyproject.toml`, `**/setup.py`
   - 의존성 파일 내에서 Grep:
     - `langchain` → **LangChain** 프리셋
     - `openai-agents` 또는 `agents-sdk` → **OpenAI Agents SDK** 프리셋
     - `autogen` → **AutoGen** 프리셋
     - `crewai` → **CrewAI** 프리셋
   - 프리셋 없이 의존성 파일만 존재 → **Python Generic** 프리셋

   **1-3. TypeScript/JavaScript 프로젝트**
   - Glob: `**/package.json`
   - package.json 내에서 Grep:
     - `@langchain` → **LangChain.js** 프리셋
     - `@openai/agents` → **OpenAI Agents SDK (TS)** 프리셋
     - `ai` (Vercel AI SDK) → **Vercel AI** 프리셋
   - 프리셋 없이 package.json만 존재 → **TS Generic** 프리셋

   **1-4. 감지 실패**
   - 위 모든 감지가 실패하면 사용자에게 질문:
     "에이전트 코드가 위치한 디렉토리와 사용 중인 프레임워크를 알려주세요."

2. 프레임워크 프리셋 기반 에이전트 탐색
   - 감지된 프리셋에 따라 에이전트/도구 파일을 탐색한다.

   **Spring AI 프리셋**
   - 에이전트 Glob: `**/*Worker*.java`, `**/*Agent*.java` (DTO, Controller, Config 제외)
   - 도구 Glob: `**/tool/**/Tool*.java`, `**/tool/**/*.java`
   - 추출 패턴:
     - 모델: `getDefaultChatModel()` 반환값
     - 역할 태그: `getWorkerType()` 반환값
     - 역할 설명: `getResourceSystemPrompt()` 내 `## Role` 또는 `## Goal` 요약
     - 도구 목록: `.tools(...)` 호출 인자
     - 도구 정의: `@Tool` 어노테이션의 `name`, `description`
     - 계층 관계: `implements` 절, 라우팅 enum (`Grep: enum.*SubWorker|SubAgent`)

   **LangChain (Python) 프리셋**
   - 에이전트 Glob: `**/*agent*.py`, `**/*chain*.py`
   - 도구 Glob: `**/*tool*.py`, `**/tools/**/*.py`
   - 추출 패턴:
     - 모델: `ChatOpenAI(model=...)`, `llm = ...` 할당문
     - 역할 설명: `system_message`, `instructions`, `SystemMessage` 내용 요약
     - 도구 목록: `tools=[...]` 인자
     - 도구 정의: `@tool` 데코레이터 + docstring, `Tool(name=..., description=...)`
     - 계층 관계: `AgentExecutor`, `create_*_agent()` 호출 관계

   **OpenAI Agents SDK 프리셋**
   - 에이전트 Glob: `**/*agent*.py`, `**/*agent*.ts`
   - 도구 Glob: `**/*tool*.py`, `**/*tool*.ts`
   - 추출 패턴:
     - 모델: `Agent(model=...)` 인자
     - 역할 설명: `Agent(instructions=...)` 인자 요약
     - 도구 목록: `Agent(tools=[...])` 인자
     - 도구 정의: `@function_tool` 데코레이터 + docstring
     - 계층 관계: `handoffs=[...]` 인자 (에이전트 간 위임)

   **Generic 프리셋 (Java/Python/TS 공통)**
   - 에이전트 Glob: `**/*Worker*.{java,py,ts}`, `**/*Agent*.{java,py,ts}`, `**/*Orchestrat*.{java,py,ts}`
   - 도구 Glob: `**/*Tool*.{java,py,ts}`, `**/*tool*.{java,py,ts}`
   - 추출 패턴: 파일 내용을 Read하여 모델명, 시스템 프롬프트, 도구 참조를 휴리스틱으로 추출
   - 불확실한 부분은 사용자에게 확인 질문

3. 에이전트 상세 분석
   - 탐색된 에이전트 파일을 모두 Read
   - 각 파일에서 프리셋의 추출 패턴에 따라 아래 정보 수집:
     - **클래스/함수명**: 에이전트 식별자
     - **기본 모델**: 사용 중인 LLM 모델
     - **역할 태그**: 내부 식별자 (LLMTag, enum 등)
     - **역할 설명**: 시스템 프롬프트 핵심 1~2문장 요약 (전문 복사 X)
     - **사용 도구**: 연결된 도구 목록
     - **연결 에이전트**: 도구를 통한 하위 에이전트 호출, handoff 관계

4. 도구 상세 분석
   - 탐색된 도구 파일을 모두 Read
   - 각 파일에서 도구 이름과 설명 추출
   - 하나의 클래스/파일에 여러 도구가 정의될 수 있으므로 모두 수집
   - 도구별로 어떤 에이전트가 사용하는지 매핑 (Step 3 결과와 교차)

5. 오케스트레이션 구조 파악
   - 라우팅/위임 관련 enum, 상수, 설정 파일 탐색
   - 모델 enum/상수 탐색
   - 에이전트 간 계층 관계 정리:
     - 오케스트레이터 → 하위 에이전트
     - 하위 에이전트 → 하위 하위 에이전트
     - 에이전트 → 도구를 통한 다른 에이전트 호출
     - handoff 기반 위임 관계

6. MD 문서 생성
   - `docs/agent-architecture.md` 파일 생성 (Write)
   - 문서 구조:

   ```markdown
   # {프로젝트명} 에이전트 아키텍처 ({브랜치명})

   > **브랜치**: `{현재 브랜치}`
   > **생성일**: {오늘 날짜}
   > **프레임워크**: {감지된 프레임워크}

   ## 1. 전체 구조 개요
   ASCII 다이어그램으로 에이전트 간 계층 구조 시각화.
   오케스트레이터 → 하위 에이전트 → 하위 하위 에이전트 흐름.
   별도 진입점 에이전트도 구분하여 표시.

   ## 2. 에이전트 상세
   에이전트 카테고리별 섹션으로 구분.
   각 에이전트:
   | 항목 | 내용 |
   |------|------|
   | **클래스** | 클래스/함수명 |
   | **태그** | 내부 식별자 |
   | **모델** | 기본 모델 |
   | **역할** | 시스템 프롬프트 기반 1~2문장 요약 |

   **사용 가능한 도구** 테이블:
   | 도구 | 용도 |
   |------|------|
   | 도구명 | description 기반 설명 |

   **연결된 에이전트**: 있으면 표기

   ## 3. 도구 상세
   카테고리별로 그룹화.
   | 도구명 | 클래스 | 용도 | 사용 에이전트 |

   ## 4. 모델 매핑
   에이전트별 기본 모델 테이블.
   지원 모델 전체 목록 (enum/상수에서 추출).
   ```

7. 결과 보고
   ```
   === 에이전트 아키텍처 문서 생성 완료 ===
   파일: docs/agent-architecture.md
   프레임워크: {감지된 프레임워크}
   에이전트: {N}개
   도구: {N}개
   브랜치: {브랜치명}
   ```
</Steps>

<Constraints>
- 코드베이스를 **읽기만** 하며, 에이전트/도구 코드를 수정하지 않는다.
- `docs/agent-architecture.md` 파일만 생성/덮어쓰기한다.
- 시스템 프롬프트의 핵심 역할만 1~2문장으로 요약하고, 전체 프롬프트를 복사하지 않는다.
- 내부 식별자(필드명, 상수명)는 사용자 친화적 설명과 함께 표기한다.
- 특정 프레임워크에 종속하지 않는다 — 기술 스택 자동 감지 후 프리셋 기반으로 동작한다.
</Constraints>

<Supported_Frameworks>
자동 감지를 지원하는 에이전트 프레임워크:

| 프레임워크 | 언어 | 감지 기준 | 에이전트 패턴 | 도구 패턴 |
|-----------|------|----------|-------------|----------|
| Spring AI | Java/Kotlin | `spring-ai` 의존성 | `AgentWorker`, `implements AgentWorker` | `@Tool` annotation |
| LangChain4j | Java | `langchain4j` 의존성 | `AiService`, `Chain` | `@Tool` annotation |
| LangChain | Python | `langchain` 의존성 | `Agent`, `AgentExecutor` | `@tool` decorator |
| OpenAI Agents SDK | Python/TS | `openai-agents` 의존성 | `Agent(name=...)` | `@function_tool` |
| AutoGen | Python | `autogen` 의존성 | `AssistantAgent`, `UserProxyAgent` | function map |
| CrewAI | Python | `crewai` 의존성 | `Agent(role=...)` | `@tool` decorator |
| LangChain.js | TypeScript | `@langchain` 의존성 | `AgentExecutor` | `tool()`, `DynamicTool` |
| Vercel AI SDK | TypeScript | `ai` 의존성 | `streamText`, `generateText` | `tool()` helper |
| Generic | 모든 언어 | fallback | `*Agent*`, `*Worker*` | `*Tool*`, `*tool*` |

감지되지 않는 프레임워크는 Generic 프리셋으로 탐색 후, 사용자에게 확인합니다.
</Supported_Frameworks>

<Examples>
```
# 기본 사용
/agent-map

# 자연어
"에이전트 구조 문서로 뽑아줘"

# 브랜치 변경 후 갱신
"release/v15.0.0 기준으로 에이전트 맵 다시 생성해줘"
```
</Examples>

<Notes>
- 에이전트가 많은 프로젝트(10개 이상)에서는 Agent 도구(subagent_type=Explore)를 활용하여 병렬 탐색하면 효율적입니다.
- 생성된 문서는 git commit하여 팀과 공유할 수 있습니다.
- 브랜치별로 에이전트 구조가 다를 수 있으므로, 문서 상단에 브랜치/날짜를 명시합니다.
- 모노레포에서는 서브 프로젝트 경로를 지정하여 특정 모듈만 분석할 수 있습니다.
</Notes>
