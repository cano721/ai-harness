# SDD 06 - 기술 스택 & 의존성

## 기술 스택

| 레이어 | 기술 | 근거 |
|--------|------|------|
| **Hook 스크립트** | Bash | 의존성 0, 모든 환경에서 동작 |
| **CLI 엔진** | TypeScript + Node.js | YAML/JSON 파싱 용이, npm 배포 |
| **테스트** | Vitest | 빠른 실행, TypeScript 네이티브 |
| **빌드** | tsup (또는 esbuild) | 빠른 번들링, CJS/ESM 지원 |
| **패키지 매니저** | npm | 표준 |

## npm 의존성

### dependencies (런타임)
```json
{
  "commander": "^12.0.0",        // CLI 프레임워크
  "yaml": "^2.4.0",             // YAML 파서
  "chalk": "^5.3.0"             // 터미널 색상
}
```

### devDependencies (개발)
```json
{
  "typescript": "^5.4.0",
  "vitest": "^2.0.0",
  "tsup": "^8.0.0",
  "@types/node": "^20.0.0"
}
```

## 의존성 최소화 원칙

- 런타임 의존성 3개 이하
- 네이티브 Node.js API 우선 사용 (fs, path, child_process)
- 대형 프레임워크 사용 금지

## Node.js 최소 버전

- Node.js >= 18 (LTS)
- 이유: fs/promises, structuredClone 등 최신 API 활용
