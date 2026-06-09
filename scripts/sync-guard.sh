#!/usr/bin/env bash
# sync-guard.sh
# 비공개 upstream(exchange-*)의 account/시크릿/네이밍이 공개 mock-* 리포로
# 새어드는 것을 푸시 전에 차단한다. SYNC.md 의 B(네이밍 변환)·C(민감정보) 위반 검사.
#
# 사용:
#   ./scripts/sync-guard.sh                 # 수동 실행
#   ln -sf ../../scripts/sync-guard.sh .git/hooks/pre-push   # 푸시 시 자동 (SYNC.md 참고)
#
# 과거 사고: upstream account 가 공개 리포에 복사되어 리포를 통째로 삭제·재생성한 적 있음.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# upstream(exchange-*) 고유 마커 — mock 에는 절대 존재해선 안 된다.
# 이 둘은 안정적이고 mock 에 0건이라 오탐이 없는 앵커다:
#   - exchange 네이밍은 변환되어야 하므로 mock 에 남으면 변환 누락
#   - account ID 는 과거 유출 사고의 본질(공개 리포에 복사됨)
# 제외한 후보와 이유:
#   - dev-jwt-secret-change-me 등 "change-me" 기본값 → mock 도 쓰는 공용 placeholder(오탐)
#   - 구체 VPC ID → 문서 예시값(vpc-0abc123def)과 충돌 + exchange VPC 는 rotate 라 마커 부적합.
#     (mock 은 <AWS_VPC_ID> placeholder 유지가 원칙이나, 이는 가드가 아닌 SYNC.md 규칙으로 다룬다.)
PATTERNS=(
  'exchange-(dev|app|gitops|infra)'   # upstream resource/repo 네이밍 변환 누락
  '483842757576'                       # exchange dev AWS account ID
)

# 가드/문서 자신은 위 마커를 예시로 포함하므로 검사 대상에서 제외한다.
EXCLUDES=(':(exclude)SYNC.md' ':(exclude)scripts/sync-guard.sh')

fail=0
for p in "${PATTERNS[@]}"; do
  if hits=$(git grep -inE "$p" -- . "${EXCLUDES[@]}"); then
    echo "❌ 금지 패턴 발견: /$p/"
    printf '%s\n' "$hits" | sed 's/^/    /'
    fail=1
  fi
done

if [[ $fail -ne 0 ]]; then
  cat <<'MSG'

→ exchange-* upstream 의 값/네이밍이 mock 으로 새어들었다.
  SYNC.md 의 규칙대로 placeholder(<AWS_ACCOUNT_ID> / <AWS_VPC_ID> 등)와
  mock-trading-platform 네이밍으로 치환한 뒤 다시 시도할 것.
MSG
  exit 1
fi
echo "✓ sync-guard 통과 — exchange upstream 마커 없음"
