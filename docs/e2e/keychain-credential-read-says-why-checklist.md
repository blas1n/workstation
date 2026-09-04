# E2E 체크리스트 — 자격증명 읽기 실패가 **이유를 말한다**

야간 러너(`scripts/e2e-live-nightly.sh`)가 Keychain 에서 라이브 E2E 자격증명을 읽을 때,
**왜 못 읽었는지**를 잃지 않고 원인별로 다르게 처신하는지 확인한다.

**고친 결함** — 읽기가 `2>/dev/null` 이었고 빈 문자열 하나가 그대로 주장이 됐다:

```bash
password=$(security find-generic-password ... -w 2>/dev/null)
if [ -z "$password" ]; then echo "SKIP: ... Keychain 에 자격증명이 없다."
```

서로 다른 두 세계가 같은 문장을 입는다:

| rc | 뜻 | 옳은 처신 |
|---|---|---|
| `44` `errSecItemNotFound` | 진짜 부재 — 사람을 기다린다 | **SKIP**, 알람 없음 |
| `36` `errSecInteractionNotAllowed` | **잠긴 keychain** — 항목이 있어도 못 읽는다 | **FAIL**, 알람 |

⭐ **왜 지금인가** — 오늘의 호출은 44 를 낸다. 지금 로그의 문장은 *우연히 참*이다.
36 이 나오는 자리는 형님이 자격증명을 **넣는 바로 그 다음**이다. 그때 러너가
*"자격증명이 없다"* 고 말하면 형님은 방금 한 일을 의심하게 된다. 실제로 이 프로젝트는
keychain 실패의 원인을 세 세션 동안 *"에이전트가 비대화형이라서 / OS 경계"* 로
적었고 전부 틀렸다. **이 로그가 원인을 재고 있었다면 세 세션을 안 썼다.**

---

## A. 유닛 — 판정 함수 (`tests/test_keychain_credential_verdict.sh`)

- [x] rc=0 + 비밀 있음 → `ok`
- [x] rc=44 → `absent` (사람 대기)
- [x] rc=36 → `unreadable` (머신 고장) — **이 파일의 존재 이유**
- [x] rc=0 인데 비밀이 비었다 → `unreadable` (rc 0 은 비밀의 존재가 아니다)
- [x] 모르는 rc(1·25·51·25308) → `unreadable`, 절대 `absent` 아님 (알람 쪽으로 실패)
- [x] 사유(36)가 잠금을 지목하고 raw stderr 를 싣는다
- [x] ⭐대조군: 사유(36)가 `"자격증명이 없다"` 를 **말하지 않는다**
- [x] 사유(44)가 부재를 말하고 `add-generic-password` 명령을 담는다
- [x] 사유는 비밀을 인자로 받지 않는다

## B. 배선 — 러너가 실제로 부르는가 (`tests/test_nightly_classifies_the_credential_read.sh`)

- [x] 러너가 lib 를 source 하고, **로드 실패를 스스로 잡는다**(빈 판정 = 미로드)
- [x] `keychain_credential_verdict` · `_reason` 을 실제로 호출한다
- [x] ⭐ 자격증명 읽기에 `2>/dev/null` 이 **없다** — stderr 를 파일로 받는다
- [x] `kc_rc=$?` 로 종료코드를 읽는다 (빈 문자열이 유일한 신호가 아니다)
- [x] `unreadable` → `fail()` (알람) · `absent` → 조용한 SKIP — 출구가 다르다
- [x] ⭐대조군: 하드코딩된 `"Keychain 에 자격증명이 없다"` 문장이 없고 사유가 판정에서 온다
- [x] `bash -n` 이 러너·lib 둘 다 통과 (절단이 구문 오류로 위장하지 않게)

## C. 전선 절단 — 각 가드가 **자기 것만** 잡는가

절단 전 실행 수를 박았다: **T1=14 · T2=13**. 다섯 절단 내내 이 수가 변하지 않았다
(변했다면 절단이 아니라 구문 오류다).

- [x] `rc=36 → absent` 로 접기 → T1 빨강 1 (`locked keychain is NOT absent`), T2 초록
- [x] 모르는 rc → `absent` → T1 빨강 5, T2 초록
- [x] 사유(36)가 "없다"고 말함 → T1 빨강 1 (대조군), T2 초록
- [x] 러너가 `2>/dev/null` 로 되돌아감 → **T2** 빨강 1, T1 초록
- [x] `unreadable` 이 `fail()` 대신 `echo` → **T2** 빨강 1, T1 초록
- [x] 전부 복구 후 둘 다 초록 · `diff` 로 원본 일치 확인

⭐ lib 절단은 T1 만, 배선 절단은 T2 만 물었다 — **하나의 가드가 둘을 덮고 있지 않다.**

## D. 라이브 — 진짜 `security` 종료코드로 (손으로 적은 숫자 아님)

- [x] 실제 부재: `security find-generic-password -s <없는것> -w` → **rc=44** 실측
- [x] 실제 잠금: `security add-generic-password` (login.keychain-db) → **rc=36**,
      `"User interaction is not allowed."` 실측
- [x] 그 두 rc 를 판정 함수에 그대로 먹여 `absent` / `unreadable` 이 나오는지 확인
- [x] 러너가 **오늘** 하는 그 호출(`-s bsvibe-e2e-live -a admin@bsvibe.dev`) → rc=44
      → `absent` → SKIP (오늘의 처신은 바뀌지 않는다: 여전히 조용히 기다린다)

## E. 러너 실행 — 진짜 스크립트를 그대로 돌렸다

⭐ 오늘의 판정이 `absent` 라 러너는 docker 스택에 **닿지 않는다**(`else` 분기 전에
SKIP). 그래서 데몬이 하는 그대로를 안전하게 한 번 돌릴 수 있었다 —
`BSVIBE_E2E_ALERT_ENV=/nonexistent` 로 형님 폰이 울리지 않게 하고:

- [x] `bash scripts/e2e-live-nightly.sh` → **exit 0**, 스택 안 뜸
- [x] SKIP 줄이 **잰 사유와 rc 를 싣는다** (하드코딩 아님):
      `SKIP: 라이브 E2E — Keychain 에 자격증명이 없다 (rc=44 errSecItemNotFound). 넣기: ...`
- [x] compose 렌더링 검사 두 절 정상 · playwright 도구 검사 통과(FAIL 없음)
- [x] LaunchAgent 는 이 워킹트리 파일을 직접 실행한다 → **배포 없이 오늘 밤 04:20 반영**

- [ ] 실제 04:20 데몬 실행에서 같은 줄 확인 (다음 세션에서 로그로)

⚠️ 라이브 실증에서 **36 을 일부러 만들지 않았다**: 그러려면 형님의 login keychain 을
잠가야 하고, 그건 이 결함보다 위험하다. 대신 36 을 **진짜 OS 에서 받아** 판정에
먹였다(D절) — 규율 117 대로 향하는 표면부터 셌다.

---

## 부수 소득 — Keychain 실패의 **진짜 원인**을 쟀다

세 세션의 진단(*"에이전트가 비대화형이라 macOS 가 거부"*, *"OS 경계"*)이 무너졌다.
같은 Background 세션에서 재본 대조군:

| keychain | `show-keychain-info` | `add-generic-password` | `find ... -w` |
|---|---|---|---|
| 내가 만들어 **잠금 해제한** probe | ✅ | ✅ | ✅ 값 읽힘 |
| `login.keychain-db` | ❌ rc=36 | ❌ rc=36 | — |

⇒ **이 세션은 keychain 쓰기를 할 수 있다.** 막힌 것은 잠긴 `login.keychain-db` 뿐이다.
그리고 야간 러너는 `gui/501`(Aqua) LaunchAgent 라 **내 Background 셸과 세션이 다르다** —
내 실패는 데몬의 실패를 예측하지 않는다.
