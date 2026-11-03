# Third-Party Licenses

이 저장소는 아래 외부 프로젝트의 Skill을 사본 또는 파생물로 포함합니다. 각 원
저작자의 라이선스를 따르며, 사본은 상류 변경을 원본에서 다시 가져옵니다.

---

## skills/feature-sliced-design

- 출처: [feature-sliced/skills](https://github.com/feature-sliced/skills)
- 라이선스: MIT (상류 README에 명시, 별도 LICENSE 파일 없음)

```
MIT License

Copyright (c) feature-sliced/skills authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## skills/no-unnecessary-effects

- 출처: [Cst2989/react-tips-skill](https://github.com/Cst2989/react-tips-skill)
- 라이선스: MIT

```
MIT License

Copyright (c) 2026 Dan Neciu

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## skills/explain-for

- 출처: [dreambigou/eli5](https://github.com/dreambigou/eli5)
- 라이선스: MIT
- 사본이 아니라 **파생물**입니다. 청자별 조정이라는 착상과 카탈로그 구조를 가져왔고, 하네스 스코프에 맞게 다시 썼습니다: 직무·숙련도 2축으로 재구성(가족·친구는 톤·비유만 정하는 관계 표로 유지), 기본 청자 "Age 5"는 유지하되 전달처가 있으면 그쪽을 먼저 추론, 아동 청자는 숙련도 단계(~5세·~10세)로 흡수, 근거 확인·데이터 취급·비수정 가드 추가.

```
MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## vendor/archify

- 출처: [tt-a1i/archify](https://github.com/tt-a1i/archify) — 릴리스 패키지(`archify.zip`)를 수정 없이 고정한 **사본**입니다. 버전·커밋·해시는 `vendor/archify.lock.json`에 있습니다
- 라이선스: MIT (`vendor/archify/LICENSE`). Cocoon-AI/architecture-diagram-generator(MIT)의 파생물이라 두 저작권 표기를 함께 둡니다
- 내장 브랜드 마크(Simple Icons 등)의 개별 라이선스·상표 고지는 `vendor/archify/THIRD_PARTY_NOTICES.md`를 따릅니다

```
MIT License

Copyright (c) 2026 tt-a1i (Archify)
Copyright (c) 2025 Cocoon AI

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## skills/landing-page

- 출처: [mengto/skills](https://github.com/mengto/skills), [greensock/gsap-skills](https://github.com/greensock/gsap-skills), [philotheephilix/reactbits.dev-skill](https://github.com/philotheephilix/reactbits.dev-skill), [KumarSashank/motiscope](https://github.com/KumarSashank/motiscope)
- 라이선스: 모두 MIT
- 사본이 아니라 **파생물**입니다. 원문 문장·예제·스크립트·컴포넌트 코드는 담지 않고, 다음 착상만 가져와 다시 썼습니다: GSAP 티커로 Lenis를 구동해 ScrollTrigger와 맞추는 구성과 JS 클래스 뒤에 숨김 상태를 두는 리빌 게이트(mengto), ScrollTrigger·프레임워크 정리 함정 목록(greensock), 컴포넌트를 기억이 아니라 레지스트리에서 받고 200 응답도 본문을 검증하며 props 타입을 읽는 규칙(reactbits.dev-skill), 영상에서 뽑은 타이밍에 측정·추정 라벨을 붙이는 규칙(motiscope). 수치는 우리 기본값이거나 WCAG 2.2·Core Web Vitals 같은 1차 출처를 따릅니다. React Bits 컴포넌트(MIT + Commons Clause)와 GSAP 라이브러리(GreenSock 자체 라이선스)는 포함하지 않으며, 사용할 때 그 라이선스를 확인하도록 Skill이 안내합니다.

```
MIT License

Copyright (c) 2026 Meng To
Copyright (c) 2026 GreenSock
Copyright (c) 2026 Philotheephilix
Copyright (c) 2026 Kumar Sashank Ghanta

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## skills/web-design-guidelines · templates/ui-review/references/web-interface-guidelines.md

- 출처: [vercel-labs/web-interface-guidelines](https://github.com/vercel-labs/web-interface-guidelines) `command.md` @ `434b7f91364665f2f733b310ec54809bf8f37937`
- 라이선스: MIT
- 규칙 본문(`references/web-interface-guidelines.md`)은 고정 커밋의 `command.md`를 바이트 그대로 담은 **사본**입니다. `SKILL.md`는 [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills)의 `skills/web-design-guidelines`(README의 MIT 표기)를 실행 때 규칙을 받지 않도록 고쳐 쓴 파생물입니다.

```
MIT License

Copyright (c) 2025 Vercel Labs

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## skills/emil-design-eng

- 출처: [emilkowalski/skill](https://github.com/emilkowalski/skill) `skills/emil-design-eng` @ `f1090bec277140d02ed202440185ad9d02ac1490`
- 라이선스: MIT
- 본문은 그대로의 **사본**이고, frontmatter에 라이선스·출처 줄만 더했습니다.

```
MIT License

Copyright (c) 2026 Emil Kowalski

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## skills/design-system-builder/references/theme-and-components.md

- 출처: [wshobson/agents](https://github.com/wshobson/agents) `plugins/ui-design/skills/design-system-patterns` @ `7e2fb559cf4b824b27f1fec49fe88f7511066d26`
- 라이선스: MIT
- 사본이 아니라 **파생물**입니다. 테마 전환(`references/theming-architecture.md`)과 컴포넌트 구조(`references/component-architecture.md`) 부분만 골라 `design-system-builder`의 토큰 규칙을 따르도록 다시 썼고, 토큰 이름·계층·대비처럼 `design-system-builder`와 겹치는 부분과 예제 코드 전문은 담지 않습니다.

```
MIT License

Copyright (c) 2024 Seth Hobson

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
