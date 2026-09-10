# E2E — 고아 폭주 탐지는 순간 CPU 로 판정

watchdog 이 `ps ... %cpu`(수명 누적 평균)로 판정해 유휴 시스템 데몬을 며칠간 오탐했다.
순간 CPU 게이트(top 2차 샘플)를 추가해 고쳤다.

## 검증 (라이브, 2026-09-10 실측)

- [x] 유닛: `bash tests/test_watchdog_orphan_detection.sh` → PASS (3케이스)
- [x] `_instant_cpu 806`(mediaanalysisd, 수명평균 172%) = **0%** — top 2차 샘플 파싱 확인
- [x] 라이브 `detect_runaway_orphans`(진짜 ps 스냅샷) → **빈 출력** (806/7758 오탐 해소)
- [x] 양성 대조군: 고아 busy loop 생성(PPID 1, 순간 93.3%) → **잡힘**, 정리 확인
- [x] `bash -n scripts/watchdog.sh` 문법 통과, lib source 배선 확인
- [ ] 다음 watchdog 주기(2분)에 텔레그램 고아 알림이 **안 옴**(오탐 중단) — 배포 후 관측
