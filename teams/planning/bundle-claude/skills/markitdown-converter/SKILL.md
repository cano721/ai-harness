---
name: markitdown-converter
description: |
  `work_support`에서 DOCX, PDF 같은 문서를 Markdown으로 변환할 때 사용하는 스킬.
  "docx를 markdown으로 바꿔줘", "pdf md 변환", "문서를 마크다운으로 추출", "markitdown으로 변환" 같은 요청에 사용한다.
  이 스킬은 로컬 래퍼 스크립트를 호출해 결과물을 원본 파일 옆 또는 지정 폴더에 저장한다.
---

# MarkItDown Converter

이 스킬은 `microsoft/markitdown`를 직접 호출하지 말고 아래 래퍼를 우선 사용한다.

- 래퍼 스크립트: `/Users/ago0528/Desktop/files/01_work/01_planning/02_work_support/scripts/markitdown_convert.sh`
- 설치 문서: `/Users/ago0528/Desktop/files/01_work/01_planning/02_work_support/docs/markitdown.md`

## When to use

- DOCX를 Markdown으로 변환해야 할 때
- PDF를 Markdown으로 변환해야 할 때
- 문서 내용을 LLM 입력용 Markdown으로 정리해야 할 때
- 여러 문서를 일괄로 `.md`로 뽑아야 할 때

## Workflow

1. 사용자가 준 입력 파일 경로를 확인한다.
2. 기본적으로 래퍼 스크립트를 실행한다.
3. 출력 경로를 따로 안 주면 원본 파일 옆에 `<원본파일명>.md`로 저장한다.
4. 여러 파일이면 `--output-dir`을 사용한다.
5. 변환 후 결과 Markdown의 앞부분을 열어 제목, 표, 목록이 대체로 정상인지 점검한다.
6. 최종 응답에는 생성된 Markdown 경로와 변환 중 주의점만 짧게 남긴다.

## Commands

단일 파일, 기본 출력:

```bash
/Users/ago0528/Desktop/files/01_work/01_planning/02_work_support/scripts/markitdown_convert.sh /absolute/path/to/file.docx
```

출력 파일 지정:

```bash
/Users/ago0528/Desktop/files/01_work/01_planning/02_work_support/scripts/markitdown_convert.sh /absolute/path/to/file.pdf --output /absolute/path/to/output.md
```

여러 파일 일괄 변환:

```bash
/Users/ago0528/Desktop/files/01_work/01_planning/02_work_support/scripts/markitdown_convert.sh /absolute/path/to/a.docx /absolute/path/to/b.pdf --output-dir /absolute/path/to/output-dir
```

## Notes

- 현재 설치는 `pdf,docx` extras 기준이다.
- 스크립트가 없거나 실행되지 않으면 `/Users/ago0528/Desktop/files/01_work/01_planning/02_work_support/docs/markitdown.md`를 보고 설치 상태를 복구한다.
- 변환 품질은 LLM 입력용 구조 보존이 목적이다. 원본 레이아웃의 완전한 재현이 목표는 아니다.
