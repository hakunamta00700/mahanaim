# Mahanaim 프로젝트 구조

**대상 독자:** 생성 프로젝트를 확장하는 개발자
**안정성 기준:** project/app generator는 stable 범위다.
**검증:** `nimble test`

`mahanaim new shop ./shop`는 빈 프로젝트가 아니라 작동하는 수직 슬라이스를
만든다. 중요한 설계 원칙은 **명시적 composition**이다. 파일을 추가하는 것만으로
route, plugin, Admin resource가 자동 등록되지는 않는다.

```text
shop/
├── .git/              Nimble 2.2 test metadata를 위한 baseline commit
├── .env.example       개발 환경 변수 예시
├── .gitignore         secret, nimcache, 실행 파일 제외
├── shop.nimble        Nimble 패키지와 binary 정의
├── src/
│   ├── shop.nim       createApp(), metadata, migration, route의 composition root
│   └── catalog.nim    mahanaim app catalog로 만드는 명시적 ApplicationModule
└── tests/
    ├── test_app.nim   생성 수직 슬라이스 회귀 테스트
    └── test_catalog.nim
```

## Composition root

생성된 `src/<project>.nim`의 `createApp*()`은 한 곳에서 다음을 조합한다.

- `newApplication(config, securityPolicy)`
- ApplicationModule과 route
- metadata, migration registry, database adapter/repository
- account authentication과 Admin registry
- shutdown hook과 application-owned CLI 구성

새 기능은 module로 분리한 뒤 root에서 설치한다.

```nim
let app = newApplication()
app.installModules([catalogModule()])
```

설치 후 `app.startup()`이 시작되면 route, provider, plugin, command 등록 창은
닫힌다. 따라서 동적 파일 스캔이나 import 부수효과에 의존하지 않는다.

## 앱 모듈

`mahanaim app NAME`은 `src/NAME.nim`의 `ApplicationModule` factory와
`tests/test_NAME.nim` 독립 테스트를 만든다. 따라서 `mahanaim app catalog`의
생성물은 `src/catalog.nim`과 `tests/test_catalog.nim`이다.
모듈에는 provider, controller, route, startup/shutdown hook, export를 명시적으로
추가할 수 있다. 자세한 API는 [애플리케이션과 모듈](application-and-modules.md)을
따른다.

## 환경 파일과 비밀값

`.env.example`은 복사 가능한 개발용 예시다. 실제 `.env`, DB credential,
`MAHANAIM_ADMIN_PASSWORD`는 git에 넣지 않는다. 설정 우선순위와 secret redaction은
[설정](configuration.md)을 참고한다.

## 확인 명령

```text
nimble test
nimble build
mahanaim check
```

`mahanaim check`은 route/config/model/migration/security/execution 계약의
부팅 전 오류를 보고한다. provider별 실제 연결 검증은 해당 live gate에서 수행한다.
