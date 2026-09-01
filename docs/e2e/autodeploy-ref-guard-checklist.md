# autodeploy 는 origin/main 만 배포한다

> 2026-09-01. 미머지 코드가 prod 에서 11분간 돌았다.

## 무슨 일이 있었나

배포 대상 디렉터리는 사람이 매일 쓰는 작업 디렉터리와 **같은 경로**다:

```bash
WORK=~/Works/${name}/main          # ← 세션이 여기서 브랜치를 팠다
LOCAL=$(git -C "$WORK" rev-parse HEAD)
GIT_SHA=$(git -C "$WORK" rev-parse --short HEAD)   # 컨테이너에 박히는 SHA
```

세션이 `$WORK` 에서 `feat/…` 브랜치를 만들어 커밋(`789a964`)하자:

1. `LOCAL(789a964) != REMOTE(40d811a)` → `needs_merge=true`
2. `git merge origin/main --ff-only` → **성공했다.** 브랜치가 main 보다 **앞서** 있으니
   "Already up to date" 다. 이 병합은 가드가 아니라 **no-op** 이었다
3. 그 워킹트리가 빌드돼 prod 에 올라갔다

```
14:42:32 [bsvibe-app] Deploying 40d811a...   ← 로그는 40d811a, 실제 빌드는 789a964
14:44:42 [bsvibe-app] Deploying 40d811a...
14:46:51 · 14:49:01 · 14:51:10 · 14:53:20    ← 2분마다 11분간
14:55:29 Stale image (deployed=40d811a vs source=baac35d) — rebuilding   ← 머지 후 정상
```

⇒ **PR 이 열려 있고 CI 가 한 번 실패한 코드가 prod 에서 돌았다.**

## 결함 셋

| # | 결함 |
|---|---|
| 1 | `--ff-only` 가 **방향을 잘못 본다** — 앞서 있는 브랜치에 대해 언제나 성공 |
| 2 | **로그가 거짓말한다** — `Deploying 40d811a` 라 적고 `789a964` 를 빌드 |
| 3 | `.deployed` 에 빌드하지 **않은** 커밋(`$REMOTE`)을 기록 → 매 사이클 재배포 루프 |

## 고친 것

* `scripts/lib/deploy_ref_guard.sh` — 명제 하나: **빌드할 HEAD 가 origin/main 인가**
* 두 배포 블록 **모두**에서 빌드 직전 호출. 거부 시 `REFUSING TO DEPLOY` 를 남기고
  `continue` / `proceed=false`
* `.deployed` 는 **빌드한 것**을 기록
* 추적파일 수정은 **경고만** — 막지 않는다(미커밋 파일이 배포를 영구 차단한 과거 함정)

## 체크리스트

- [x] `HEAD == origin/main` 이면 배포한다
- [x] 배포 디렉터리에서 브랜치를 파면 **거부**하고, 사유가 **브랜치명과 HEAD 를 댄다**
- [x] `merge --ff-only` 가 성공한 **뒤에도** 가드가 거부한다 (거짓 가드 실증)
- [x] detached HEAD 도 거부
- [x] untracked 잔여물(`.vercel/` 등)은 배포를 **막지 않는다**
- [x] 부재가 성공을 흉내내지 못한다 — 함수 미정의 시 테스트가 즉시 실패
- [x] 배포 블록 **각각**이 자기 가드를 갖는다 (블록 경계로 갈라 검사)
- [x] 전선을 끊어 빨강 실증 — bsvibe-app 가드만 제거 → **3개 단언 사망**
- [x] bash **3.2** 에서 돈다 (launchd 가 `/bin/bash` 로 돌린다 — `mapfile` 없음)
- [x] 실제 `$WORK` 에 대해 읽기 전용 검증 — 현재 상태에서 통과(배포 정상)
- [ ] 라이브 실증 — 배포 디렉터리에서 브랜치를 파고 폴러가 거부하는지 로그 확인

## ⚠️ 라이브 실증이 남은 이유

내용이 main 과 동일한 **빈 커밋**으로 사고 조건만 재현하려 했으나, 배포 디렉터리에서
브랜치를 파는 행위 자체가 권한 정책에 막혔다 — 정확히 그 위험한 행위이기 때문이다.
그래서 배선을 **정적으로** 고정했다(`tests/test_autodeploy_calls_the_ref_guard.sh`).

다음에 누가 실증하려면: `$WORK` 에서 `git commit --allow-empty` 로 브랜치를 만들고
2분 뒤 `logs/autodeploy.log` 에 `REFUSING TO DEPLOY` 가 찍히는지 본 뒤 main 으로 복귀.
**빈 커밋을 써라** — 가드가 틀려도 prod 는 main 과 같은 트리를 빌드한다.

## 테스트

```bash
/bin/bash tests/test_deploy_ref_guard.sh              # 가드 자체 (실 git 픽스처 6케이스)
/bin/bash tests/test_autodeploy_calls_the_ref_guard.sh # 배선 — 둘 다 부르는가
```

## 남은 갭 (의도적)

추적파일 수정은 경고만 하고 배포된다. 막으면 prod 가 벽돌이 될 수 있어서다
(미커밋 파일이 autodeploy 를 영구 차단한 전례). 보이게 만들고 판단은 사람에게.
