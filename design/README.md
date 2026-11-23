# 와이어플로우

앱 전체 화면과 화면 사이의 이동을 한 장에서 눌러 보는 더미다. 시각 디자인이 아니라 구조와 흐름을 점검하는 용도다.

- `pondu.html` 브라우저에서 바로 연다. 인터넷 연결이 필요 없다.
- `pondu.flow.json` 원본. 화면 31개, 경로 7개, 요구사항 13개, 정해야 할 것 5개.
- `make-flow.py` 원본 JSON을 만드는 스크립트.

출처는 `docs/PRD.md` v0.4, `docs/specs/CONTRACT-ADDENDUM.md` 보정 3, `ios/PonduKit`의 화면 구현이다. PRD에 없이 넣은 화면(할 일 없음, 친구 없음)은 `inferred`로 표시했다.

## 다시 만들기

```sh
python3 design/make-flow.py
node .agents/skills/wireflow-review/scripts/wireflow.cjs check design/pondu.flow.json
node .agents/skills/wireflow-review/scripts/wireflow.cjs build design/pondu.flow.json design/pondu.html
```

## 고칠 때

HTML에서 화면을 고르고 **수정 요청**을 적은 뒤 **수정 요청 목록**을 복사해 에이전트에게 붙여 넣는다. 에이전트는 `.agents/skills/wireflow-review/SKILL.md`를 따른다.

## 확인한 것

- `[모의]` 도구의 정적 검사: 문제 0건, 경로 7/7 통과.
- `[모의]` 브라우저(Chromium)에서 HTML의 흐름 검증: 요구사항 13개 통과. 더미 화면을 누른 결과이고 실제 앱을 누른 것이 아니다.
- 실제 앱 화면과 한 줄씩 대조하지는 않았다. 화면 문구와 버튼 배치는 실제 앱과 다를 수 있다.
