# SDD 05 - CLI 명령어 상세 스펙

## 공통

```
진입점: bin/ai-harness.js
프레임워크: commander.js (또는 yargs)
```

---

## 1. ai-harness init

### 입력
```
Options:
  --team <teams>       팀 쉼표 구분 (예: frontend,backend)
  --preset <name>      프리셋 (fullstack, product, all)
  --no-omc             OMC 없이 Core 모드
  --dry-run            실제 변경 없이 계획만 출력
  --non-interactive    대화형 프롬프트 없이 기본값
```

### 처리
```
1. 환경 감지
   - Node.js 버전 확인 (>=18)
   - Git 저장소 확인 (.git/ 존재)
   - Claude Code 설치 확인 (claude --version)
   - 기존 .ai-harness/ 존재 여부

2. 팀 결정
   - --team 옵션이 있으면 사용
   - --preset이 있으면 프리셋에서 팀 목록 추출
   - 없으면 프로젝트 파일 기반 자동 추천 후 확인

3. 스택 감지
   - package.json → Node.js/React/Next.js
   - build.gradle/pom.xml → Java/Spring Boot
   - tsconfig.json → TypeScript

4. 설정 파일 생성
   - .ai-harness/config.yaml 생성
   - .ai-harness/hooks/ 디렉토리에 Hook 스크립트 복사 + chmod +x

5. CLAUDE.md 주입
   - claudemd-injector로 규칙 주입

6. settings.json 등록
   - settings-manager로 Hook 등록
```

### 출력
```
✔ .ai-harness/config.yaml 생성
✔ Hook 3개 등록
✔ CLAUDE.md 업데이트
✔ 설치 완료 (팀: frontend, backend / Hook: 3개)
```

---

## 2. ai-harness status

### 입력
없음 (현재 디렉토리 기준)

### 처리
```
1. .ai-harness/config.yaml 로드
2. 팀, 버전, Hook 상태 수집
3. 감사 로그 오늘 요약 (있으면)
```

### 출력
```
AI Harness v1.0.0
팀: frontend, backend
Hook: 3개 활성 (block-dangerous 🔒, audit-logger 🔒, secret-scanner 🔒)
오늘 로그: 42건 (차단 2건)
```

---

## 3. ai-harness doctor

### 입력
없음

### 처리
```
1. 환경 검증
   - Node.js, Git, Claude Code 버전

2. 하네스 검증
   - config.yaml 파싱 가능 여부
   - lock-policy 준수 여부

3. Hook 검증
   - 각 Hook 파일 존재 + 실행 권한
   - settings.json에 등록 여부

4. CLAUDE.md 검증
   - harness:start ~ harness:end 구간 존재 여부
```

### 출력
```
[환경]  ✔ Node.js v20.x  ✔ Git  ✔ Claude Code
[하네스] ✔ config.yaml  ✔ 잠금 정책
[Hook]  ✔ block-dangerous  ✔ audit-logger  ✔ secret-scanner
[규칙]  ✔ CLAUDE.md 하네스 구간 존재
결과: 이상 없음 ✅
```

---

## 4. ai-harness hook test [hook-name]

### 입력
```
hook-name: 선택. 없으면 전체 Hook 테스트
--all: 전체 Hook
```

### 처리
```
1. Hook 스크립트 경로 결정
2. 테스트 정의 YAML 로드 (<hook-name>.test.yaml)
3. 각 케이스 실행 + 판정
```

### 출력
```
block-dangerous: 5/5 ✅
audit-logger:    3/3 ✅
secret-scanner:  8/8 ✅
전체: 16/16 통과 ✅
```
