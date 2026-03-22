# Смежные работы и границы новизны

## Узкая формулировка новизны

Этот репозиторий не заявляет новизну в следующих вещах:

- CAEP / SSF / SET как стандарты
- Envoy как программируемый прокси в плоскости данных
- OPA или внешний механизм авторизации в момент запроса как базовые строительные блоки авторизации
- Redis как низколатентный кэш состояния отзыва
- continuous authorization как общая исследовательская область

Защищаемый вклад уже и точнее:

- стандартизованный приём событий класса SSF / CAEP
- связывание идентификаторов по `sub` / `sid` / `jti`
- немедленное действие в плоскости данных над уже активными HTTP/2 gRPC-потоками в Envoy
- воспроизводимое сравнение с тремя реальными открытыми архитектурами сравнения
- минимальная формализация свойств revoke-to-terminate и no-new-stream-after-revoke

Иными словами, вклад работы не в “reactive IAM вообще”, а в следующую цепочку:

`стандартизованное событие -> связывание идентификаторов -> применение политики к активному потоку в Envoy -> измеряемое сравнение с базовыми архитектурами`

## Что уже реально интегрировано в этом репозитории

Чтобы не смешивать literature review и фактическую реализацию, важно разделять два уровня:

- основной экспериментальный набор из трёх реально интегрированных и проверенных открытых архитектур сравнения:
  - OPA + Envoy
  - Istio `CUSTOM` external authz
  - OpenFGA через адаптер авторизации в момент запроса
- эти три проекта покрывают три разные архитектурные линии:
  - внешнюю авторизацию в момент запроса на уровне прокси
  - внешнюю авторизацию в сервисной сетке
  - централизованную детализированную авторизацию
- в архитектуре также уже присутствует локальный OSS OIDC/JWKS IdP, через который идут итоговые проверки и полный набор экспериментов
- локальные инженерные абляции и вспомогательные контуры сравнения отделены от основной публичной витрины и не влияют на центральные графики

## OSS-примеры push / event dissemination, близкие к теме

В открытом доступе есть OSS-артефакты, которые полезны именно как ориентир для push-доставки security events, но не как полноценная архитектура сравнения для воздействия на уже активные потоки:

- `SGNL caep.dev receiver`: open-source приёмник для SSF / CAEP, полезен как ориентир для приёма событий
- OpenID Shared Signals / CAEP ecosystem resources: полезны как ориентир для модели событий и взаимодействия transmitter / receiver

Именно поэтому в этой работе они используются как ориентиры по стандартам, а не как честные архитектуры сравнения по механизму применения политики. Для основной публичной витрины здесь оставлены `OPA + Envoy`, `Istio CUSTOM` и `OpenFGA`.

## Почему не "чистая OPA"

В этой теме некорректно говорить об архитектуре сравнения как о просто ``OPA'' без указания точки исполнения политики. Причина в том, что OPA сама по себе не является прокси Envoy и не принимает на себя управление уже активным gRPC-потоком. В типичном open-source развёртывании OPA выступает как внешний PDP, а роль PEP и сетевой точки применения решения выполняет прокси, шлюз или компонент сервисной сетки.

Поэтому в этом репозитории честная открытая архитектура сравнения формулируется именно как:

- `OPA + Envoy`

а не как абстрактная ``чистая OPA''. Это делает сравнение архитектурно сопоставимым:

- в предлагаемом режиме PEP расположен в Envoy в плоскости данных;
- в архитектуре `OPA + Envoy` PEP также расположен в Envoy, но решение делегируется внешнему PDP на базе OPA;
- различие между режимами тогда интерпретируется как различие механизма применения политики, а не как различие несопоставимых моделей развёртывания.

## Матрица сравнения с OSS-проектами

Таблица ниже намеренно консервативна. Возможность отмечается только тогда, когда она явно присутствует в публичном артефакте проекта, а не просто близка по духу.

| Проект / стек | Стандартизованный SSF / CAEP ingest | Интеграция с Envoy / mesh | Request-time deny для нового трафика | Завершение активного stream | Воспроизводимый K8s-ориентированный demo | Что именно даёт |
| --- | --- | --- | --- | --- | --- | --- |
| [SGNL caep.dev receiver](https://socket.dev/go/package/github.com/sgnl-ai/caep.dev-receiver) | Да | Нет прямого Envoy enforcement | Нет | Нет | Библиотека / примеры | Open-source библиотека receiver для SSF; полезна как reference для parsing и polling, но не как stream enforcer в data plane |
| [OpenID sharedsignals resources](https://openid.net/wg/sharedsignals/) | Да | Нет прямого Envoy enforcement | Нет | Нет | Гайд / playground | Материалы стандартизации и экосистемы; подтверждают модель сигналов, но не дают enforcement-механизм |
| [OPA-Envoy plugin](https://www.openpolicyagent.org/docs/envoy) | Нет стандартного CAEP path по умолчанию | Да | Да | Нет | Да | Канонический request-time baseline для external authorization в Envoy |
| [OPA Envoy SPIRE example](https://github.com/open-policy-agent/opa-envoy-spire-ext-authz) | Нет | Да | Да | Нет | Example-oriented | Хороший пример external authorization в service-to-service среде, но всё ещё только request-time |
| [SPIFFE / SPIRE Envoy + OPA tutorial](https://spiffe.io/docs/latest/microservices/envoy-opa/readme/) | Нет стандартного CAEP path по умолчанию | Да | Да | Нет | Да | Сильная интеграция workload identity с Envoy и OPA, но без реактивного per-stream revocation |
| [Kuadrant Authorino](https://docs.kuadrant.io/latest/authorino/docs/getting-started/) | Нет стандартного CAEP path по умолчанию | Да | Да | Нет | Да | Kubernetes-native external authn/authz сервис для Envoy-based gateway; релевантен как API authorization comparator, но не как active-stream enforcement |
| [Envoy Gateway SecurityPolicy](https://gateway.envoyproxy.io/docs/concepts/introduction/gateway_api_extensions/security-policy/) | Нет стандартного CAEP path по умолчанию | Да | Да | Нет | Да | Kubernetes-native упаковка external authorization для Envoy Gateway |
| [Istio CUSTOM external authz](https://istio.io/latest/docs/tasks/security/authorization/authz-custom/) | Нет стандартного CAEP path по умолчанию | Да | Да | Нет | Да | Интеграция mesh с внешним authorizer для request-time проверок |
| [Linkerd policy / authorization](https://linkerd.io/2/reference/authorization-policy/) | Нет стандартного CAEP path по умолчанию | Да, но в собственном mesh-стеке | Да | Нет | Да | Service-mesh comparator для policy-driven допуска трафика, но без event-driven per-stream termination в Envoy |
| [Kong OPA plugin](https://docs.konghq.com/hub/kong-inc/opa/) | Нет стандартного CAEP path по умолчанию | Да, но в gateway-стеке Kong | Да | Нет | Да | Официальный request-time OPA comparator для API gateway path; полезен как ещё один proxy-based baseline, но не как active-stream enforcer |
| [Traefik ForwardAuth](https://doc.traefik.io/traefik/reference/routing-configuration/http/middlewares/forwardauth/) | Нет | Да, но через middleware / forward auth | Да | Нет | Да | Типичный OSS comparator для внешней request-time авторизации на proxy edge, без адресного завершения уже активного stream |
| [Emissary AuthService / ExtAuth](https://emissary-ingress.dev/docs/3.6/topics/running/services/auth-service/) | Нет стандартного CAEP path по умолчанию | Да, на Envoy-based gateway | Да | Нет | Да | Envoy-based gateway comparator с внешним auth service; релевантен как request-time access control, но не как reactive per-stream termination |
| [Apache APISIX authz-keycloak](https://apisix.apache.org/docs/apisix/plugins/authz-keycloak/) | Нет стандартного CAEP path по умолчанию | Да, но в gateway-стеке APISIX | Да | Нет | Да | Gateway-level authorization через Keycloak / UMA; усиливает сравнение с OSS request-time authorization stacks, но не закрывает reactive revoke-to-stream-reset |
| [Pomerium](https://www.pomerium.com/docs) | Нет | Да, как identity-aware proxy / ingress authorizer | Да | Нет | Да | Зрелый OSS access proxy для request-time identity checks и policy enforcement на входе, но не для адресного завершения уже активного Envoy-managed gRPC stream |
| [Gloo Gateway external auth](https://docs.solo.io/gloo-edge/latest/guides/security/auth/extauth/) | Нет стандартного CAEP path по умолчанию | Да, в gateway-стеке на базе Envoy | Да | Нет | Да | Ещё один сильный Envoy-based comparator для внешней request-time авторизации; релевантен как gateway baseline, но не как per-stream revoke enforcer |
| [Keycloak Authorization Services](https://www.keycloak.org/docs/latest/authorization_services/) | Нет | Косвенно, как внешний IdP / PDP | Да | Нет | Да | Зрелый OSS-компонент policy-based authz и claims evaluation; релевантен как comparator уровня решения, но не как reactive data-plane enforcer |
| [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/) | Нет | Косвенно, через front proxy / ingress | Да | Нет | Да | Популярный OSS-компонент для request-time authentication / authorization на входе, но не для per-stream terminate в Envoy data plane |
| [ORY Oathkeeper](https://www.ory.sh/docs/oathkeeper/) | Нет | Косвенно, как access proxy / authorizer | Да | Нет | Да | Policy-driven access proxy для API gateway сценариев; близок по классу задачи, но не по механике active-stream enforcement |
| [ORY Keto](https://www.ory.sh/keto/docs/) | Нет | Косвенно, как внешний authorization engine | Да | Нет | Да | OSS relation-based authorization engine; усиливает сравнение по линии “внешний PDP / authz engine”, но не решает revoke-to-stream-reset в data plane |
| [Cerbos](https://www.cerbos.dev/docs) | Нет | Косвенно, как внешний PDP | Да | Нет | Да | Внешний policy decision point для приложений и gateway-интеграций; хороший comparator для request-time PDP, но не для revoke-to-stream-reset |
| [Casbin](https://casbin.org/) | Нет | Косвенно, как библиотека или внешний policy engine | Да | Нет | Да | Очень популярный OSS policy engine; полезен как comparator класса authorization core, но не как стандартизованный SSF / CAEP receiver и не как Envoy stream enforcer |
| [OpenFGA](https://openfga.dev/docs) | Нет | Косвенно, как внешний authorization engine | Да | Нет | Да | Relationship-based authorization engine; в этом репозитории уже интегрирован как живой request-time comparator через адаптер авторизации, но не является mid-stream enforcer сам по себе |
## Граница сравнения

Набор сравнения выше намеренно ориентирован на соседние open-source системы, которые действительно может назвать рецензент:

- стандартизованные SSF / CAEP receivers
- контуры авторизации в момент запроса на базе Envoy или сервисной сетки
- внешние OSS PDP / authorization engines, которые часто используются рядом с proxy-based enforcement
- Kubernetes-упаковка вокруг внешней авторизации для Envoy

Общий пробел у них один и тот же, и именно его закрывает этот проект:

- они умеют запретить новый запрос
- они не умеют, как основную документированную возможность, переводить revoke-style событие в адресное прерывание уже активного Envoy-managed gRPC stream

## Почему проект всё ещё научно интересен

Относительно open-source систем выше этот репозиторий добавляет недостающий end-to-end path:

- приёмник, который принимает стандартизованные события отзыва
- реактивный Envoy PEP, который отслеживает активные downstream gRPC-потоки
- применение политики к уже активным потокам, а не только к повторному подключению
- базовая архитектура сравнения, которая показывает противоположное поведение:
  запрет нового запроса работает, но уже допущенный поток продолжает жить до естественного завершения

Текущий минимальный набор по честному OSS-сравнению уже закрыт тремя путями:

- OPA + Envoy
- Istio `CUSTOM` external authz
- архитектура `OpenFGA`

Это отражено в центральном наборе результатов и сводном отчёте:

- [experiments/results/matrix-summary-full.json](../../experiments/results/matrix-summary-full.json)
- [experiments/results/matrix-report-full.json](../../experiments/results/matrix-report-full.json)

Поэтому работу нужно описывать как:

- системный вклад в continuous / usage-style authorization для long-lived потоков
- не как утверждение, что CAEP, Envoy или continuous authorization были изобретены здесь
- не как абсолютное “мы первые в мире”

Корректная формулировка выглядит так:

> В пределах проведённого обзора не найден зрелый open-source end-to-end артефакт, который переводит finalized SSF / CAEP-style события в per-stream termination уже активных Envoy-managed gRPC потоков.

## Границы текущей реализации

- текущая обязательная часть покрывает `session-revoked` и одно deny-causing risk / claim update событие
- текущее связывание использует явные заголовки `x-sub`, `x-sid` и `x-jti`
- реализация ориентирована на HTTP/2 gRPC streaming
- в публичный воспроизводимый стенд входит локальный OSS OIDC/JWKS IdP
