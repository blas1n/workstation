# E2E — autodeploy self-disruption 가드 생존 판정

**대상**: `scripts/autodeploy.sh` self-disruption 가드 + `scripts/lib/run_liveness.sh`
**유닛 테스트**: `tests/test_run_liveness.sh` (실 Postgres 픽스처 8케이스)

## 배경 — 무엇이 깨졌었나

2026-08-18, 런 `abe9e2b9` 가 살아있는 채로 컨테이너 재생성에 깔려 죽었다.
가드 로그가 스스로를 고발한다:

| 시각 (KST) | 사건 |
|---|---|
| 14:46:52 | `1 executor run(s) in flight — deferring` |
| 14:48:57 | `1 executor run(s) in flight — deferring` |
| **14:51:01** | 가드 통과 → backend+worker **force-recreate** |
| 이후 | 런 활동 0건, `claimed_at` 05:47:38 에서 정지 |

원인: 가드가 `updated_at > now() - interval '3 minutes'` 로 생존을 판정했다.
그런데 그 런 자신의 선언 검사 `uv run pytest -ra` 는 **353초**가 걸렸고,
런은 **8분 39초**(05:19:52 → 05:28:31) 동안 DB에 아무것도 쓰지 않았다.

앱 자신의 계약은 정반대를 말한다
(`agent_worker._stale_claim_lease_s`, `_drive_loop`):

> `claimed_at` 은 **턴 경계에서만** 갱신된다. 한 턴은 최대 `executor_task_timeout_s`
> (기본 **1시간**) 까지 정당하게 걸릴 수 있고, stale-claim lease 는 그 2배(**2시간**)다.

**가드의 3분은 앱의 1시간 계약보다 20배 짧았다.** `watchdog.sh` 의 wedge 임계값도
이미 2시간이다 — 3분만이 예외였다.

## 검증 항목

- [x] 유닛: 턴 중간 5분 침묵 + claim 유지 → **보호** (구 가드는 미보호 → RED 확인함)
- [x] 유닛: 50분짜리 긴 턴, lease 이내 → **보호**
- [x] 유닛: claim 이 lease(2h) 초과 → 보호 안 함 (앱 리퍼 담당)
- [x] 유닛: 형님 결정 대기(`claimed_at` NULL) → 보호 안 함
- [x] 유닛: `open`(미클레임) → 보호 안 함 — **구 가드는 이걸 보호해 배포를 괜히 막았다**
- [x] 유닛: 워커가 claim 이후 기동 → **고아 claim**, 보호 안 함
- [x] 유닛: 워커가 claim 이전부터 기동 → 보호
- [x] `bash -n scripts/autodeploy.sh` 통과
- [x] launchd 가 절대경로로 호출하므로 `$(dirname "$0")/lib/...` 소싱이 성립
- [x] E2E: 실 prod DB 에 새 가드 SQL 그대로 실행 → 고아 claim 런(`abe9e2b9`)을
      **보호하지 않음**(0). 죽은 런 하나가 lease 2시간 동안 배포를 막지 않는다
- [x] E2E: **살아있는 런**이 도는 동안 새 가드가 1 을 반환 (구 가드가 0 을 반환하는
      침묵 구간에서) — 실 런 `e02846b8` 로 확인 (2026-08-18 07:02~07:05 UTC)

## E2E 실증 기록 — 런 `e02846b8`

20초 간격 폴링. 런은 살아서 일하는 중이었고 07:05:57 에 `review_ready` 로 정상 완료했다.

| 시각 (UTC) | 새 가드 | 구 가드 | DB 침묵 |
|---|---|---|---|
| 07:02:14 | **1 (보호)** | **0 (방치)** | 190s |
| 07:03:55 | **1** | **0** | 292s |
| 07:05:36 | **1** | **0** | **393s** |
| 07:05:57 | 0 | — | 런 완료 (`review_ready`) |

**3분 22초 동안 구 가드는 이 살아있는 런을 보호하지 않았다.** 최대 침묵 393초 =
구 가드 180초 창의 2.2배. 그 사이에 배포가 떨어졌으면 `abe9e2b9` 와 같은 죽음이었다.

## 되돌리는 법

`scripts/lib/run_liveness.sh` 의 `run_liveness_sql` 만 되돌리면 된다.
`autodeploy.sh` 는 이 함수만 부른다.


## 프로덕션 실증 — 가드가 스스로 증명했다 (2026-08-18, 계획 밖)

`#773` 머지 직후 자동배포가 재빌드를 시도했고, 그때 런 `b5644558` 이 돌고 있었다.

| 시각 (KST) | 사건 |
|---|---|
| 16:21:10 | `Stale image (8a21644 → 10d6823) — rebuilding` 시도 |
| **16:23:15** | **`1 executor run(s) in flight — deferring`** ← 새 가드가 막음 |
| 16:24:23 (UTC 07:24) | 런 `b5644558` 완료 → `claimed_at` 해제 |
| 16:25:19 | 연기 없이 재빌드 → `Done` 16:25:47 |

**살아있는 런이 끝날 때까지 기다렸다가, 끝나자마자 배포했다.**
구 가드였다면 이 런도 `abe9e2b9` 와 같은 죽음이었다 — 완료 직전 구간은
검증(전체 pytest)이라 `updated_at` 이 3분 창 밖이다.
