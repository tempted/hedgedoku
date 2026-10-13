# 고슴도쿠 (웹 버전)

색깔 덤불마다 고슴도치를 한 마리씩, 서로 닿지 않게 배치하는 논리 퍼즐이에요.
설치 없이 브라우저에서 바로 플레이할 수 있고, 휴대폰에서는 "홈 화면에 추가"로 앱처럼 쓸 수 있어요.

## 폴더 구성

| 파일 | 내용 |
|---|---|
| `index.html` | 게임 본체 |
| `config.js` | 리더보드(Supabase) 주소와 공개 키. **배포 전에 채워야 해요** |
| `sw.js` | 오프라인 지원 (한 번 열면 인터넷 없이도 플레이 가능) |
| `manifest.webmanifest`, `icons/` | 홈 화면 아이콘과 앱 이름 |
| `supabase/setup.sql` | 리더보드 DB를 만드는 SQL |
| `tools/` | 아이콘 원본 (배포에는 필요 없음) |

## 1단계: Supabase로 리더보드 만들기 (약 5분)

1. https://supabase.com 에 가입하고 **New project**를 만들어요.
   - 이름은 자유 (예: `hedgedoku`), 지역은 **Northeast Asia (Seoul)** 추천
   - Database password는 아무 값이나 정하면 돼요 (이 게임에서는 쓰지 않음)
2. 프로젝트가 준비되면 왼쪽 메뉴 **SQL Editor** → **New query**
3. `supabase/setup.sql` 내용을 전부 붙여 넣고, `<GitHub아이디>` 부분을 내 GitHub Pages 주소로 바꾼 뒤 **Run** (그 주소의 게임에서만 기록이 저장돼요)
   - 마지막에 "Success. No rows returned"가 나오면 끝이에요.
   - 예전에 setup.sql을 실행한 프로젝트라면 `supabase/` 폴더의 `fix-security-definer-view.sql`, `fix-security-definer-functions.sql`, `profile-avatar.sql`, `origin-check.sql`(주소 바꾸기)을 차례로 실행해 최신 구조로 맞춰요.
4. 왼쪽 메뉴 **Project Settings → API** (또는 **Data API**)에서 두 값을 복사해요.
   - **Project URL** (예: `https://abcdefghijklmnop.supabase.co`)
   - **anon / public** 키 (긴 `eyJ...` 문자열, 또는 새 프로젝트라면 `sb_publishable_...`로 시작하는 키)
5. `config.js`를 열어 두 값을 넣고 저장해요.

```js
window.HEDGEDOKU_CONFIG = {
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabaseAnonKey: 'eyJhbGciOi...',
};
```

> anon/public 키는 브라우저에 공개되도록 만들어진 키라 GitHub에 올려도 괜찮아요.
> **service_role(secret) 키는 절대 넣지 마세요.** 그 키가 있으면 누구나 DB를 마음대로 바꿀 수 있어요.

`config.js`를 비워 두면 리더보드 없이 게임만 동작해요.

## 2단계: GitHub Pages로 공개하기 (약 5분)

1. https://github.com 에 로그인하고 오른쪽 위 **+ → New repository**
   - Repository name: `hedgedoku` (원하는 이름)
   - **Public** 선택 → **Create repository**
2. 새 저장소 화면에서 **uploading an existing file** 링크를 눌러요.
3. `hedgedoku-web` 폴더 **안의 내용물**(index.html, config.js, sw.js, manifest.webmanifest, icons 폴더, supabase 폴더)을 끌어다 놓고 **Commit changes**
   - 폴더 자체가 아니라 안의 파일들을 올려야 `index.html`이 저장소 맨 위에 와요.
4. 저장소 **Settings → Pages**
   - Source: **Deploy from a branch**
   - Branch: **main**, 폴더 **/(root)** → **Save**
5. 1~2분 뒤 같은 화면 위쪽에 주소가 나와요: `https://<GitHub아이디>.github.io/hedgedoku/`

## 업데이트할 때

1. 바뀐 파일을 같은 방법으로 다시 올려요 (같은 이름이면 덮어써져요).
2. **`sw.js` 맨 위의 `VERSION` 값을 올려 주세요** (예: `hedgedoku-v1` → `hedgedoku-v2`).
   안 그러면 이미 플레이한 사람들은 오프라인 캐시 때문에 예전 버전을 한동안 보게 돼요.

## 휴대폰에서 앱처럼 쓰기

- **아이폰**: 사파리로 주소를 열고 → 공유 버튼 → **홈 화면에 추가**
- **안드로이드**: 크롬으로 주소를 열고 → 메뉴(⋮) → **홈 화면에 추가** 또는 **앱 설치**

## 리더보드 동작 방식

- 처음 접속한 브라우저마다 임의의 플레이어 ID와 비밀값이 만들어져요. 기록은 이 ID로 묶여요.
- 위쪽 **내 프로필** 버튼에서 이모지(12가지 중 하나)와 닉네임을 정하고 바꿀 수 있어요.
  프로필 없이 첫 기록을 올리면 임시 닉네임(예: 고슴도치1234)과 임의의 이모지로 등록돼요.
- 기록은 난이도마다 개인 최고 기록 하나만 남아요 (레벨 수가 많을수록, 같으면 누적 시간이 짧을수록 위).
- 브라우저 데이터를 지우거나 다른 기기에서 하면 새 플레이어로 인식돼요.
- 점수는 플레이어 브라우저에서 계산해서 올리는 방식이라, 마음먹고 조작하는 사람을 완전히 막을 수는 없어요.
  서버에서는 "한 레벨에 1초 미만" 같은 말이 안 되는 값과 남의 기록 덮어쓰기만 막아요.

### 기록 관리 (Supabase 대시보드)

- 기록 보기: **Table Editor → scores / players**
- 기록 지우기: 해당 행을 선택해 삭제 (`players` 행을 지우면 그 사람의 기록도 함께 지워져요)
- 부적절한 닉네임: `players` 테이블에서 `nickname`을 직접 고치거나 행을 삭제

## 로컬에서 실행해 보기

서비스 워커 때문에 파일을 더블클릭해서 열면 일부 기능이 동작하지 않아요. 이 폴더에서:

```bash
python -m http.server 8642
```

그다음 브라우저에서 http://localhost:8642 를 열면 돼요.
