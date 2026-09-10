# BSVibe 복원 런북 (게이트 3)

`backup.sh` 가 매일 03:00 에 ① PG 덤프(`bsvibe_DATE.sql.gz`) ② vault+skills
(`vault_DATE.tgz`)를 로컬(`~/backups/bsvibe`, 14일)과 **R2**(`r2:bsvibe-backups`)에
둔다. 이 문서는 그걸 **되돌리는** 절차다(감사 §Ⅳ: 복원 런북 부재 해소).

⚠️ R2 토큰은 버킷-스코프라 **List/Delete 불가**. 파일명을 알아야 가져온다
(파일명 = `bsvibe_YYYY-MM-DD_HHMM.sql.gz` / `vault_...tgz`; 로컬 보존분에서 확인).

## 0. 전제: docker(colima) 가 떠 있어야 한다
```sh
docker info >/dev/null 2>&1 || colima start   # 안 뜨면 먼저 이것부터
docker ps | grep bsvibe-prod-postgres-1        # 컨테이너 확인
```

## 1. R2 에서 백업 가져오기 (로컬에 없을 때)
```sh
# IPv4 강제(토큰이 호스트 IPv4 에 allow-list). 파일명은 알고 있어야 함.
V4=$(ipconfig getifaddr "$(route -n get default | awk '/interface:/{print $2}')")
rclone copyto "r2:bsvibe-backups/bsvibe_2026-09-10_0300.sql.gz" ./db.sql.gz \
  --bind "$V4" --s3-no-check-bucket
rclone copyto "r2:bsvibe-backups/vault_2026-09-10_0300.tgz"    ./vault.tgz \
  --bind "$V4" --s3-no-check-bucket
```

## 2. DB 복원
⚠️ **기존 데이터를 덮어쓴다.** 신규/빈 DB 로 먼저 검증한 뒤 전환을 권한다.
```sh
# (권장) 빈 DB 에 복원해 무결성 확인
docker exec -i bsvibe-prod-postgres-1 psql -U bsvibe -c "CREATE DATABASE bsvibe_restore;"
gzip -dc db.sql.gz | docker exec -i bsvibe-prod-postgres-1 psql -U bsvibe -d bsvibe_restore
docker exec bsvibe-prod-postgres-1 psql -U bsvibe -d bsvibe_restore -c "SELECT count(*) FROM workspaces;"
# 확인되면 live 로 (다운타임 감수; 백엔드 정지 후):
#   gzip -dc db.sql.gz | docker exec -i bsvibe-prod-postgres-1 psql -U bsvibe -d bsvibe
```

## 3. vault + skills 복원
```sh
# tgz 루트가 vault/ 와 skills/ 이므로 /app/var 에 풀면 제자리로 간다.
docker exec -i bsvibe-prod-backend-1 tar xzf - -C /app/var < vault.tgz
docker exec bsvibe-prod-backend-1 sh -c 'ls /app/var/vault | head; du -sh /app/var/vault'
```

## 4. 재기동 + 검증
```sh
cd /Users/blasin/Works/bsvibe-app/main/deploy
docker compose -p bsvibe-prod -f compose.yaml -f compose.prod.yaml --env-file .env.prod up -d
curl -fsS -o /dev/null -w "%{http_code}\n" https://api.bsvibe.dev/api/v1/health   # 404=정상
for l in com.bsvibe.worker com.bsvibe.worker-admin com.bsvibe.worker-mac-mini-e2e; do
  launchctl kickstart -k gui/501/$l; done
```

## 복구 리허설 (분기 권장)
위 1~3 을 **신규 DB(`bsvibe_restore`) + 임시 dir** 로 한 번 돌려 백업이 실제로
복원되는지 확인한다. "백업이 있다"와 "복원된다"는 다르다(감사 §Ⅳ).
