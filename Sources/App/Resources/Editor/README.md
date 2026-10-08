# 오프라인 Milkdown 편집기

앱은 `index.html`, `editor.css`, `editor.js`만 로컬에서 읽는다.
Milkdown 7.22.2, ProseMirror 및 highlight.js 11.11.1은 생성 JS에 포함되며 외부 import는 빌드에서 거부한다.
`editor.js`, `editor.sha256`, `LICENSES.txt`, `bun.lock`을 함께 배포한다.

```sh
bun install --frozen-lockfile --ignore-scripts
bun test
bun run build --clean
shasum -a 256 -c editor.sha256
```

`--clean`은 앱 Resources에 개발 의존성이 복사되지 않도록 node_modules를 제거한다.
CSP는 외부 스크립트와 fetch 연결을 금지한다. 이미지는 data URL 및 HTTP/HTTPS를 허용한다.
문서 상대 로컬 이미지는 호스트가 PNG data URL로 전달한다.

## 두 모드

`configuration.mode`는 `raw`(기본) 또는 `preview`이다.
사용자 표시 이름은 Edit / Preview다. `showsModeToggle: true`일 때만 고정 웹 헤더가 표시된다.
오른쪽 모드 버튼의 클릭은 기존 v1
envelope에 `type: "modeToggle"`을 보내며 클라이언트가 직접 모드를 바꾸지 않는다.
Edit의 왼쪽 도구 9개는 `type: "format"`으로 원문 서식 명령을 전달한다.

Raw는 Milkdown의 단일 `raw_source` code/text 노드와 ProseMirror view/history다.
Markdown 파싱이나 직렬화를 전혀 사용하지 않는다. 화면 줄끝은 LF이고
원문 mirror 및 history step이 혼합 CRLF/LF/lone CR을 보존한다.
선택은 원문 UTF-16 좌표로 전송하며 CRLF 중간 좌표는 앞 경계로 정규화한다.
일반 Enter는 첫 원문 줄끝을 사용하고 paste 및 host replacement는 그대로 보존한다.
Preview는 같은 원문을 Milkdown CommonMark/GFM으로 파싱한 읽기 전용 문서다.
Preview snapshot은 원문 mirror와 마지막 raw 선택을 그대로 반환한다.
모드 왕복은 raw history를 보존한다. Edit는 논리 줄 번호와 언어별 구문 강조를 제공한다.
줄 번호는 편집 DOM 밖에 있고 화면 줄바꿈 좌표를 따른다. Preview의 코드 블록에도
구문 강조를 적용하고 체크리스트의 완료 상태를 표시한다.
슬래시 메뉴나 대화형 표 편집을 위한 별도 서식 편집 모드는 제공하지 않는다.

## 브리지

`initialize`, `flush`, `apply`(`configure`/`format`/`replace`), `resume`, `dispose`와
`ready`/`state`/`snapshot`/`applied` envelope는 기존 ABI 그대로다.
`replace`는 epoch를 변경하고 undo를 비우며 `format`은 독립 undo 항목이다.
`flush`는 compositionend 신호와 microtask 뒤 PM `domObserver.forceFlush()`로
최신 DOM 입력을 반영하고 편집을 잠근다. 숨겨진 탭에서 rAF를 기다리지 않는다.
PM 내부 API는 lockfile 버전에 고정된다. 업그레이드 시 WK IME 회귀를 다시 실행한다.
`active: false`는 초기 focus를 얻지 않으며 명시적 configure로 focus를 해제한다.
원문/preview 모두 OS clipboard에는 copy 이벤트에서만 접근한다.
Preview copy는 DOM 선택으로부터 의미 HTML과 문법 없는 일반 텍스트를 제공하고
class/style/data-* 및 UI 요소를 제거한다. Raw copy는 원문 literal text만 제공한다.
체크리스트의 완료 상태는 HTML과 일반 텍스트에 체크 기호로 유지한다.

읽기 전용 `window.markAgentEditorView` getter는 WK 통합 테스트용 실제 PM view다.
텍스트 transaction은 `view.dispatch(view.state.tr.insertText(text, from, to))`를
사용한다. Raw PM 좌표는 LF 텍스트 offset + 1이다. 실제 WK/IME와 프로세스
누수 검증은 호스트 테스트에서 수행한다. Bun 테스트는 실제 Milkdown을 happy-dom에
마운트하며 DOM flush, history, clipboard 이벤트, 모드 왕복과 dispose를 검증한다.
