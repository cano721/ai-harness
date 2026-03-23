import { writeFile, readFile } from 'fs/promises';
import { stringify, parse } from 'yaml';

export interface ConventionAnswers {
  domain: string;
  entities: string[];
  // BE
  basePackage?: string;
  apiPrefix?: string;
  responseFormat?: string;
  dtoPattern?: string;
  dbMigration?: string;
  // FE
  framework?: string;
  stateManagement?: string;
  componentDir?: string;
  // 공통
  testFramework?: string;
  coverageTarget?: number;
}

function buildBackendConvention(answers: ConventionAnswers): string {
  const pkg = answers.basePackage ?? 'com.company';
  const apiPrefix = answers.apiPrefix ?? '/api/v1';
  const dtoPattern = answers.dtoPattern ?? '{Action}{Entity}Request';
  const dbMigration = answers.dbMigration ?? 'flyway';
  const coverage = answers.coverageTarget ?? 80;
  const testFramework = answers.testFramework ?? 'junit';
  const entities = answers.entities;
  const exampleEntity = entities[0] ?? 'Entity';
  const responseFormat = answers.responseFormat ?? '{ code, message, data }';

  const dbSection =
    dbMigration === 'liquibase'
      ? `- DDL 변경: Liquibase 체인지셋 사용\n- SQL 파라미터 바인딩 필수 (문자열 연결 금지)\n- \`SELECT *\` 금지, 필요한 컬럼만 명시\n- \`@Transactional\` 적절한 사용`
      : `- DDL 변경: Flyway 마이그레이션 (\`V{timestamp}__{desc}.sql\`)\n- SQL 파라미터 바인딩 필수 (문자열 연결 금지)\n- \`SELECT *\` 금지, 필요한 컬럼만 명시\n- \`@Transactional\` 적절한 사용`;

  return `---
name: convention-backend
description: Backend 코드 컨벤션 — 패키지 구조, API 규칙, DTO 네이밍, 예시 코드
team: backend
trigger: "컨벤션|convention|코드 규칙|코딩 규칙"
---

# Backend 코드 컨벤션

## 도메인
- ${answers.domain}
- 주요 엔티티: ${entities.join(', ')}

## 패키지 구조
\`\`\`
${pkg}.{도메인}.controller  — REST API
${pkg}.{도메인}.service     — 비즈니스 로직
${pkg}.{도메인}.repository  — JPA Repository
${pkg}.{도메인}.dto         — Request/Response DTO
${pkg}.{도메인}.entity      — JPA Entity
\`\`\`

## DTO 네이밍
- \`${dtoPattern}\` / \`{Action}{Entity}Response\`
- 예: \`Create${exampleEntity}Request\`, \`Get${exampleEntity}Response\`

## API 규칙
- RESTful, 버저닝 필수: \`${apiPrefix}/...\`
- 응답 포맷:
\`\`\`json
${responseFormat}
\`\`\`
- 페이징: \`Pageable\` (page, size, sort)
- Swagger 어노테이션 필수 (\`@Operation\`, \`@ApiResponse\`)

## 예외 처리
- \`BusinessException(code, message)\` 사용
- \`@ControllerAdvice\`로 전역 처리
- HTTP 상태: 400 (요청 오류), 404 (미존재), 409 (충돌), 500 (서버 오류)

## 로깅
- \`@Slf4j\` 사용 (System.out 절대 금지)
- \`log.info\` (정상), \`log.warn\` (경고), \`log.error\` (에러)

## DB
${dbSection}

## 테스트
- 프레임워크: ${testFramework}
- 커버리지 목표: ${coverage}% 이상

## 예시: ${exampleEntity} 목록 조회 API

\`\`\`java
@RestController
@RequestMapping("${apiPrefix}/${exampleEntity.toLowerCase()}s")
@RequiredArgsConstructor
@Slf4j
public class ${exampleEntity}Controller {

    private final ${exampleEntity}Service ${exampleEntity.charAt(0).toLowerCase() + exampleEntity.slice(1)}Service;

    @Operation(summary = "${exampleEntity} 목록 조회")
    @GetMapping
    public CommonResponse<Page<Get${exampleEntity}Response>> get${exampleEntity}s(Pageable pageable) {
        return CommonResponse.success(${exampleEntity.charAt(0).toLowerCase() + exampleEntity.slice(1)}Service.get${exampleEntity}s(pageable));
    }
}
\`\`\`
`;
}

function buildFrontendConvention(answers: ConventionAnswers): string {
  const framework = answers.framework ?? 'react';
  const stateManagement = answers.stateManagement ?? 'zustand';
  const componentDir = answers.componentDir ?? 'src/components';
  const coverage = answers.coverageTarget ?? 80;
  const testFramework = answers.testFramework ?? 'vitest';
  const entities = answers.entities;
  const exampleEntity = entities[0] ?? 'Item';

  const stateSection =
    stateManagement === 'redux'
      ? `- 글로벌 상태: Redux Toolkit\n- 서버 상태: RTK Query`
      : stateManagement === 'pinia'
        ? `- 글로벌 상태: Pinia\n- 서버 상태: Vue Query`
        : `- 글로벌 상태: Zustand\n- 서버 상태: React Query (캐싱, 동기화, 재시도)`;

  const isVue = framework === 'vue';
  const componentExt = isVue ? 'vue' : 'tsx';

  return `---
name: convention-frontend
description: Frontend 코드 컨벤션 — 컴포넌트 구조, 상태 관리, API 호출, 성능 기준, 예시 코드
team: frontend
trigger: "컨벤션|convention|코드 규칙|코딩 규칙"
---

# Frontend 코드 컨벤션

## 도메인
- ${answers.domain}
- 주요 엔티티: ${entities.join(', ')}

## 기술 스택
- ${framework.charAt(0).toUpperCase() + framework.slice(1)} + TypeScript

## 디렉토리 구조
\`\`\`
${componentDir}/
  {feature}/          # 기능별 컴포넌트
    {Component}.${componentExt}
  common/             # 공통 컴포넌트
src/api/
  {domain}.ts         # API 호출 hook
\`\`\`

## 컴포넌트 규칙
- Props 타입은 \`interface\`로 정의 (\`type\` 키워드 사용 금지)
- 파일명은 PascalCase
- moment.js 금지 → dayjs 사용

## 상태 관리
${stateSection}

## 테스트
- 커버리지 ${coverage}% 이상
- ${testFramework} + Testing Library
- 사용자 행동 기반 테스트 (구현 세부사항 테스트 지양)

## 예시: ${exampleEntity} 컴포넌트

\`\`\`tsx
interface ${exampleEntity}CardProps {
  id: string;
  name: string;
}

export function ${exampleEntity}Card({ id, name }: ${exampleEntity}CardProps) {
  return (
    <div className="${exampleEntity.toLowerCase()}-card">
      <span>{name}</span>
    </div>
  );
}
\`\`\`
`;
}

function buildGenericConvention(team: string, answers: ConventionAnswers): string {
  const coverage = answers.coverageTarget ?? 80;
  const testFramework = answers.testFramework ?? 'jest';

  return `---
name: convention-${team}
description: ${team.charAt(0).toUpperCase() + team.slice(1)} 팀 코드 컨벤션
team: ${team}
trigger: "컨벤션|convention|코드 규칙|코딩 규칙"
---

# ${team.charAt(0).toUpperCase() + team.slice(1)} 코드 컨벤션

## 도메인
- ${answers.domain}
- 주요 엔티티: ${answers.entities.join(', ')}

## 테스트
- 프레임워크: ${testFramework}
- 커버리지 목표: ${coverage}% 이상

## 기본 규칙
- 코드 리뷰 필수
- 의미 있는 변수/함수명 사용
- 함수는 단일 책임 원칙 준수
`;
}

export async function generateConventionSkill(
  team: string,
  answers: ConventionAnswers,
  outputPath: string,
): Promise<void> {
  let content: string;
  if (team === 'backend') {
    content = buildBackendConvention(answers);
  } else if (team === 'frontend') {
    content = buildFrontendConvention(answers);
  } else {
    content = buildGenericConvention(team, answers);
  }
  await writeFile(outputPath, content, 'utf-8');
}

export async function saveConventionConfig(
  answers: ConventionAnswers,
  configPath: string,
): Promise<void> {
  await writeFile(configPath, stringify(answers), 'utf-8');
}

export async function loadConventionConfig(configPath: string): Promise<ConventionAnswers> {
  const raw = await readFile(configPath, 'utf-8');
  return parse(raw) as ConventionAnswers;
}
