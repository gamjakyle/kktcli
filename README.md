# kktcli — macOS용 카카오톡 CLI

[English](README.en.md) · [사용법](USAGE.md) · [구조](ARCHITECTURE.md)

`kktcli`(KaKaoTalk CLI)는 macOS용 카카오톡(KakaoTalk for Mac)을 터미널과 코딩
에이전트에서 다루는 비공식 CLI입니다. 채팅 목록과 메시지를 **읽는 것**을 중심으로
만들었습니다. macOS 손쉬운 사용(Accessibility) API로 화면에 보이는 카카오톡 앱을
읽을 뿐, 카카오 서버나 비공개 프로토콜(LOCO)에는 접속하지 않습니다.

kktcli는 [channprj/kmsg](https://github.com/channprj/kmsg)(MIT 라이선스)를 포크해
고친 프로젝트입니다. 원작자 Park Hee Chan 님과 kmsg 기여자들께 감사드립니다.
무엇이 달라졌는지는 아래 [kmsg와 달라진 점](#kmsg와-달라진-점)에 정리했습니다.

## 안전과 정책

먼저 읽어 주세요.

- **카카오와 무관합니다.** kktcli는 카카오(Kakao Corp.)가 만들거나 승인한 도구가
  아니며, 카카오톡 자동화에 대한 공식 허가를 받지 않았습니다.
- **정지 위험은 '접속 방식'과 '쓰는 패턴'에 따라 다릅니다.**
  - kktcli는 공식 카카오톡 앱을 손쉬운 사용 기능으로 다룰 뿐, 카카오 서버나 비공개
    프로토콜(LOCO)에 직접 접속하지 않습니다.
  - 영구정지 이야기가 나오는 쪽은 주로 LOCO에 직접 접속하는 비공식 클라이언트입니다.
    kmsg 개발자 문서([ARCHITECTURE.md](https://github.com/channprj/kmsg/blob/main/ARCHITECTURE.md))도
    그렇게 언급합니다. 다만 출처가 제시된 통계는 아니고, 카카오가 공개한 자료도 아닙니다.
  - kmsg처럼 손쉬운 사용 방식을 쓰는 도구로 계정이 정지됐다는 사례는 2026년 11월 기준
    GitHub 이슈와 웹 검색에서 찾지 못했습니다. 이런 도구는 나온 지 오래되지 않았고
    사용자도 많지 않아서, 사례가 없다는 것이 안전을 보장하지는 않습니다.
  - 방식과 상관없이, 짧은 시간에 메시지를 많이 보내거나 채팅방을 많이 만들면 카카오의
    자동 감지로 이용이 제한될 수 있습니다([카카오톡 운영정책 – 자동감지](https://talksafety.kakao.com/measure/detection)).
  - 카카오가 이런 자동화를 공식으로 허용한 적은 없고, 운영정책은 "카카오톡이 허용하지
    않는 방법"의 이용을 제한할 수 있다고 정하고 있습니다([운영정책](https://talksafety.kakao.com/policy/stability/abnormalusage)).
    사용에 따른 책임은 사용자에게 있습니다.
- **읽기 우선 설계입니다.** `chats`와 `read`는 키보드 입력이나 마우스 클릭을 만들어
  보내지 않고, 손쉬운 사용 API로 화면을 읽고 정해진 버튼·메뉴 항목만 누릅니다.
  카카오톡이 뒤에 있어도 동작합니다.
- **대량 발송에 쓰지 마세요.** `send`, `send-image`는 남아 있지만 사용자가 직접
  요청한 한 건씩만 보내는 용도입니다. 여러 방·여러 사람에게 반복해서 보내는 데
  쓰면 스팸으로 보고 계정이 제한될 수 있습니다.
- **안 읽은 방도 열고, 열면 읽음 처리됩니다.** `read`는 안 읽은 메시지가 있는 방도
  사람이 직접 열 때처럼 열기 때문에 상대에게 읽음 표시가 전달됩니다. 읽음 표시를
  남기지 않으려면 `--skip-unread`를 주세요. 채팅 목록에 안읽음 표시가 보이는 방은 열지
  않고 `UNREAD_REFUSED`(종료 상태 3)로 멈춥니다. 지금 kktcli로 안 읽은 메시지를 읽음
  처리 없이 볼 수 있는 것은 `chats`가 보여 주는 마지막 메시지 미리보기뿐입니다.
- **대화 내용은 이 Mac에 남습니다.** kktcli에는 네트워크 코드가 없습니다. 다만 출력을
  AI 서비스(코딩 에이전트, 챗봇 등)에 넘기면 그 내용이 해당 회사로 전송됩니다.
  대화 상대의 개인정보도 함께 넘어가므로 필요한 만큼만 읽어 주세요.
- **저장 위치:** `~/.kktcli`(채팅 레지스트리, 화면 경로 캐시)와 `~/.config/kktcli`
  (암호화한 로그인 정보, 암호화 키도 같은 Mac에 있음). 설치된 kmsg의 `~/.kmsg`,
  `~/.config/kmsg`는 읽지도 쓰지도 않습니다.

## kmsg와 달라진 점

| 영역 | kmsg 1.260921.0 | kktcli 0.1.0 |
|---|---|---|
| 방 열기 | 행 선택 + Enter, 검색창 입력, 더블클릭(키·마우스 이벤트) | 채팅 목록 행의 메뉴 항목 **채팅방 열기**만 손쉬운 사용 동작으로 누름. 키 입력 없음, 카카오톡이 뒤에 있어도 동작 |
| 안 읽은 방 | 그대로 열어 읽음 표시 전달 | 사람이 열 때처럼 열어 읽음 표시 전달, `--skip-unread`면 열지 않음(`UNREAD_REFUSED`), JSON에 열기 전후 안읽음 표시(`unread_before`·`unread_after`·`marked_read`) |
| `read --chat-id` | 호출마다 채팅 목록 약 200행 재스캔 | 레지스트리의 마지막 위치부터 찾고 일치하면 멈춤 |
| `chats` 제목 | 안읽음 배지 문구가 방 제목으로 표시되는 경우 있음 | 제목 라벨(`_NS:40`)에서만 제목을 읽음, `has_unread`/`unread_count` 추가 |
| 메시지 파싱 | `date`가 비고, 연속 메시지 시간이 앞 메시지 시간으로 채워짐 | 날짜 구분선으로 `date`, 연속 메시지 시간 추론(`time_source`: `label`/`inferred`), 보낸 사람 이어받기, 채널 배너를 `(me)`로 오인하지 않음 |
| 이전 메시지 | 처음 로드된 행만 | 스크롤백(`--scrollback`, 시간 제한 있음) |
| 창 닫기 | 첫 번째 버튼을 누르거나 Cmd+W | 창의 닫기 버튼만 누름, 없으면 열어 두고 알림 |
| 키 입력 경로 | 앞에 있는 앱 확인 없음 | 보내기·로그인 등 키 입력이 필요한 경로는 카카오톡이 맨 앞일 때만 입력 |
| `--json` | 결과가 없거나 실패하면 일반 텍스트 | 항상 JSON 한 개(오류 코드·종료 상태 포함) |
| 목록 상태 복구 | 없음 | 검색어로 걸러진 채팅 목록, 닫힌 메인 창을 정해진 버튼·메뉴로만 복구 |
| 팀채팅 | 검색 경로에서 실패할 수 있음 | 행 제목 `팀채팅, <이름>`과 창 제목 `<이름>`을 맞춰 처리 |
| 배포 | `update` 명령, Homebrew, 릴리스 자동화 | 소스 빌드만, 네트워크 코드 없음, 데이터 폴더 분리 |
| MCP | `kmsg_*` 도구 | `kktcli_*` 도구, `skip_unread`·스크롤백 옵션, 읽기 오류 코드 전달 |

## 측정 결과

조건: Mac 1대, KakaoTalk for Mac 26.10.0, 계정 1개, 방 20개, 방마다 최신 메시지
20개. 세 도구 모두 같은 Codex 모델이 사용했습니다.

| 항목 | kktcli 0.1.0 | kmsg 1.260921.0 | Codex Computer Use |
|---|---|---|---|
| 읽기에 성공한 방 | 20/20 | 17/20 | 20/20 |
| 방 하나에 걸린 시간(중앙값) | 3.2초(2.4–9.9초) | 33초(그중 kmsg 실행 32초) | 59초 |
| 메시지 재현율 | 99.7% | 87.9%(실패한 방 포함) | 98.1% |
| 보낸 사람 정확도 | 100% | 97% | 99.7% |
| 시간 표시가 있는 메시지의 시간 정확도 | 100% | 98% | 100% |

kktcli 세부 결과:

- 합성 키보드·클릭 이벤트 0건, 카카오톡은 계속 뒤에 있었고, 연 창은 모두 닫기
  버튼으로 닫혔습니다. 팀채팅, 나와의 채팅, 채널 방 4곳도 모두 읽었습니다.
- `chats`: 182행에 6.8초, 제목과 안읽음 표시 182/182 정확.
- 스크롤백: 날짜가 붙은 메시지 200개를 17초에 읽음.
- 복구: 보이는 검색 상태 복원(취소 → 검색 순서로 누름), 닫힌 메인 창은
  **카카오톡 열기** 메뉴로 다시 열림(이때 카카오톡이 앞으로 나옵니다), 없는 방은
  `CHAT_NOT_IN_LIST`, 잘못된 인자는 JSON 오류와 종료 상태 64. 검색창이 숨은 채
  필터만 남은 상태는 실측에서 재현하지 못해 **검증되지 않았습니다**.

kmsg의 실패: 채널 방 2곳과 팀채팅 1곳에서 실패했고, 다른 팀채팅 1곳은 한 번 실패하며
검색창에 검색어를 남겼습니다. 팀채팅이 실패하는 이유는 kmsg의 검색 보조 경로가
`팀채팅, <이름>`으로 검색하는데, 카카오톡 검색은 이 접두어가 붙은 이름을 찾지
못하기 때문입니다(0건, 접두어 없이 검색하면 1건). 그래서 행 선택 + Enter 단계가
빗나가면 팀채팅은 복구되지 않습니다. 행 선택 + Enter 자체는 채팅 목록에 포커스가
있을 때 10/10 성공했습니다.

한계: Mac 1대·계정 1개·방 20개의 작은 표본입니다. 정확도의 기준(정답)은 손쉬운 사용
API로 읽어 만든 것이라 kktcli와 데이터 출처가 같으므로, kktcli에 유리하게 나왔을 수
있습니다.

## 요구 사항

- macOS 13 이상
- KakaoTalk for Mac. **26.10.0(빌드 2010)에서만 시험했습니다.** 다른 버전에서는
  화면 구조가 달라 동작하지 않을 수 있습니다.
- 실행하는 `kktcli` 바이너리에 손쉬운 사용 권한
- 소스 빌드용 Swift 6 이상(Xcode 또는 Command Line Tools)

## 소스에서 빌드·설치

```bash
swift build -c release
mkdir -p ~/.local/bin
install -m 0755 .build/release/kktcli ~/.local/bin/kktcli
kktcli --version   # 0.1.0 (based on kmsg 1.260921.0)
kktcli status      # 손쉬운 사용 권한, 카카오톡 실행·로그인 상태 확인
```

`~/.local/bin`이 `PATH`에 있어야 합니다. **시스템 설정 → 개인정보 보호 및 보안 →
손쉬운 사용**에서 실행하는 바로 그 바이너리를 켜 주세요. 다시 빌드하거나 옮긴
바이너리는 다시 추가해야 할 수 있습니다.

## 빠른 시작

```bash
kktcli chats --json --limit 30                    # 방 목록, chat_id, 안읽음 여부
kktcli read --chat-id "<chat_id>" --limit 20 --json
kktcli read "방 이름" --limit 200 --scrollback      # 이전 메시지까지
kktcli read "방 이름" --json --background-safe      # 이미 열린 창만 읽기
```

`read`는 이미 열린 창이 있으면 그 창을 읽고, 없으면 채팅 목록에서 방을 찾아 열고,
다 읽은 뒤 닫습니다. 명령과 옵션은 [USAGE.md](USAGE.md)에 있습니다.

## 코딩 에이전트 스킬

[`skills/kktcli`](skills/kktcli/SKILL.md)는 코딩 에이전트가 kktcli를 안전하게 쓰는
절차입니다(읽기 우선, 안 읽은 방을 열면 읽음 처리된다는 점 알리기, 보내기는 명시적
요청과 dry-run 뒤 한 번만).
Claude Code에서는 이 폴더를 `~/.claude/skills/kktcli`에 복사하면 `/kktcli`로 쓸 수
있습니다. 다른 에이전트는 해당 에이전트의 스킬 설치 방법을 따르세요.

## MCP 서버

```bash
kktcli mcp-server
```

stdio MCP 서버로 `kktcli_read`, `kktcli_send`, `kktcli_send_image` 도구를 제공합니다.
`kktcli_read`는 `skip_unread`, `scrollback`, `scrollback_timeout` 옵션을 받고, 실패하면
`UNREAD_REFUSED` 같은 kktcli 오류 코드를 그대로 돌려줍니다. 예전 옵션 `allow_unread`는
받기만 하고 무시합니다. 설정 예시는
[USAGE.md](USAGE.md#mcp-server)에 있습니다.

## 문서

- [USAGE.md](USAGE.md) — 명령, 옵션, JSON 형식, 오류 코드, 설정, 문제 해결
- [ARCHITECTURE.md](ARCHITECTURE.md) — 구조와 설계 결정

## 감사의 말

kktcli는 [channprj/kmsg](https://github.com/channprj/kmsg)에서 출발했습니다. kmsg는
[steipete/imsg](https://github.com/steipete/imsg)와
[OpenClaw](https://github.com/openclaw/openclaw)에서 영감을 받았습니다.

## 라이선스

[MIT 라이선스](LICENSE). 원본 kmsg 저작권 표시를 그대로 두고, 이 포크의 변경분에 대한
저작권 표시를 추가했습니다.
