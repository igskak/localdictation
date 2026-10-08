# Witness для Windows — план реализации

Дата: 2026-09-27. Обновлено: 2026-10-08. Статус: W0–W8 реализованы
до unsigned internal beta; запланирован W9 для догоняющего обновления до
продуктового baseline Witness 0.6.14.

Текущая цель — сохранить уже реализованный отдельный Windows-клиент и довести
его до функционального соответствия Witness 0.6.14, не выдавая перенос
macOS-специфичного кода за Windows-проверку. После W9 остаются прежние внешние
гейты подписанной закрытой беты: реальные credentials, legal review, code
signing и физическая Windows 11 QA. Разработчик работает на Mac, локальную
Windows/виртуальную машину не устанавливает. Сборка и автоматические проверки
выполняются на Windows в CI; проверку настоящих микрофонов, скорости и
совместимости пользователь закажет после получения подписанной беты.

**Готовность к передаче тестировщикам и готовность к продаже — разные контрольные точки.** Непроверенные на физических Windows-компьютерах свойства должны оставаться явно непроверенными. Этот документ не подтверждает качество распознавания или совместимость ещё не существующей сборки.

## 1. От какой версии переносим

Первоначальная Windows-реализация корректно начиналась с опубликованного
Witness 0.6.8, build 9, commit
`c073a8fbad5fe1cca7ef6dcf06fc7c19c2c89b77`. Этот commit остаётся историческим
общим предком и объясняет существующие parity-тесты, но больше не является
целевой версией продукта.

**Новый подтверждённый target — Witness 0.6.14, build 15, tag `v0.6.14`, commit
`e5954f7e4d4d75c1c5ab0e7bebe21495d4437221`**, выпущенный 2026-10-07.
Проверка выполнена 2026-10-08 по локальным Git objects, tag и `origin/main`;
версия/build сверены с Xcode-проектом этого commit. На момент аудита Windows
head `5be4a72` и `v0.6.14` имеют общий предок `v0.6.8`: после него Windows-линия
содержит 81 собственный commit, а продуктовая линия — 29. Поэтому обновление
делается интеграцией двух линий и повторной проверкой контрактов, а не заменой
Windows-кода содержимым `main`.

Windows beta пока сохраняет независимую версию `0.1.0`, build 1. Обновление
product parity baseline до 0.6.14 само по себе не разрешает переименовывать
Windows-пакет: общая или независимая нумерация должна быть принята отдельно,
потому что version/build участвуют в updater и licensing contracts.

Первый вариант этого плана ошибочно принимал тогдашнее локальное рабочее дерево
за актуальную продуктовую основу. Исторический контекст:

- Локальный `HEAD`: `f66081e59839c8af6bcfcddec64c8992fb0ad391` (`Ship German as 0.5.0`).
- Локальные незакоммиченные файлы показывают `0.6.2`, build `3`; это **не** последняя версия продукта.
- Исходный baseline переноса: **исходники commit `c073a8fbad5fe1cca7ef6dcf06fc7c19c2c89b77` / release `v0.6.8`**. Он не заменяется задним числом: W9 явно обновляет его до 0.6.14.
- Новые локальные правки учитывать отдельно, только после сравнения с release baseline: нельзя подменить ими более новые реализованные функции и исправления.
- WhisperKit закреплён на `1.1.0`, Sparkle — на `2.10.0`; наличие Windows solution/CI повторно проверять в выбранной ветке перед стартом.
- Проверены metadata опубликованного релиза и его исходники; сам DMG здесь не запускался, работа deployed activation service не проверялась.

Перед каждым новым catch-up снова проверить latest published release, точный tag
commit и локальные изменения; обновить target, если вышла новая версия. Не
выполнять reset/stash/очистку и не коммитить чужие изменения вместе с
Windows-кодом. Таблица ниже описывает исходное поведение релиза 0.6.8, уже
перенесённое в W0–W8; следующий подраздел фиксирует обязательную дельту до
0.6.14.

| Область | Текущее поведение, которое переносим | Основной источник |
| --- | --- | --- |
| Жизненный цикл | Приложение в menu bar, настройки, первый запуск, автозапуск, горячая клавиша | `LocalDictation/Application/`, `Features/MenuBar/`, `Services/Launch/` |
| Запись | Hold-to-talk и toggle, настраиваемое сочетание; конфликт возвращает прежнее рабочее сочетание | `Models/Preferences.swift`, `Services/Hotkey/`, `Features/Dictation/DictationCoordinator.swift` |
| Аудио | Mono Float32 16 kHz, ограниченный буфер; по умолчанию 300 секунд, верхний предел настройки 600; тишина не обрезает сказанное | `Services/Audio/`, `Services/VAD/` |
| Выбор микрофона | Встроенный / системный / конкретный; выбор сохраняется, применяется со следующей записи, не меняет системный input; fallback при исчезновении | `Services/Audio/SystemAudioInput.swift`, `Models/Preferences.swift` |
| Прерывания | При исчезновении микрофона уже записанные слова проходят распознавание; причина показывается отдельно | `DictationCoordinator.swift`, `CaptureInterruptionTests.swift` |
| Распознавание | Whisper large-v3 turbo локально; автоматическая загрузка отсутствующей модели; одна общая операция загрузки, прогресс и восстановление после ошибки | `Services/Transcription/WhisperKitTranscriptionService.swift` |
| Выбор языка и скорость 0.6.8 | Язык определяется по завершённой записи, без решения по первым 1.5 секундам; повторный encoder pass одного и того же окна переиспользуется только при идентичном входе внутри этой диктовки | `Services/Transcription/EncoderOutputReuse.swift`, `WhisperKitTranscriptionService.swift`, `EncoderReuseParityTests.swift` |
| Языки | Выбор из каталога движка, строго внутри выбранного набора; временная фиксация одного языка; предыдущий язык учитывается до 120 секунд | `Models/LanguageCatalog.swift`, `Services/Transcription/LanguageDecision.swift`, `LanguagePinTests.swift` |
| Проверка результата | Консервативная очистка с картой изменений; числа/даты/суммы, имена, glossary, malformed words, смена языка, cleanup и confidence | `Services/Cleanup/`, `Services/Risk/`, `Models/RiskSpan.swift` |
| Порог предупреждений | Attention 0.8, display 0.3; вес model confidence **0**; имена сами по себе не требуют внимания | `Services/Review/ReviewCoordinator.swift`, `Models/RiskSpan.swift` |
| Вставка | Захват приложения в начале записи, проверка назначения перед записью/вставкой; прямой путь, paste, clipboard fallback; защищённые поля исключены | `Services/Insertion/`, `Models/InsertionOutcome.swift` |
| Проверка paste | Изменение курсора ещё не доказывает вставку текущего текста; при сомнении новая диктовка остаётся в clipboard; старое содержимое возвращается только после проверки и при неизменённом clipboard | `AXTextInsertionService.swift`, `InsertionPolicy.swift`, `Pasteboard.swift` |
| Обратная связь | Индикатор recording/processing у курсора, не забирающий фокус и пропускающий клики; различаются отсутствие речи и пустой результат STT | `Features/Dictation/DictationActivityPanelController.swift`, `Models/SilentResult.swift` |
| Review | Вставка не ждёт проверки пользователем; индикатор внимания, raw/cleaned text, replay отмеченного фрагмента из RAM | `Features/Review/`, `DictationCoordinator.swift` |
| История | Последние 10 непустых результатов, только текст, только до завершения сессии; раскрываемый список с видимой высотой viewport и прокруткой; отказ из-за защищённого поля не создаёт запись | `RecentDictation`, `Features/MenuBar/MenuBarView.swift`, `RepeatedDictationTests.swift`, `SettingsViewLayoutTests.swift` |
| Настройки | General, Languages, Boundary, Dictionary, License, Diagnostics; настройки VAD и language pin не переживают перезапуск | `Features/Settings/SettingsView.swift`, `Services/Preferences/` |
| Лицензия | 3 дня без email от первого непустого результата; активированный trial выдаётся сервером на 10 дней от активации; annual/lifetime, два устройства, offline Ed25519 | `EntitlementPolicy.swift`, `LicenseKey.swift`, `Service/src/activate.js` |
| Оплата | Активация по email с немедленным принятием ключа, ручной ввод, освобождение устройства, checkout в браузере после согласия; в Mac сейчас €99 lifetime / €49 annual | `Features/Licensing/`, `Services/Licensing/`, `Service/` |
| Lifetime | Покрывает купленную major-версию и её обновления; первая major — 1, таблица последующих пока пустая | `Services/Licensing/LifetimeUpdatePolicy.swift` |
| Обновления | Settings → Check for updates; подписаны каталог и пакет; нет автоматических проверок, установки и profiling | `Services/Updates/AppUpdater.swift`, `Resources/Info.plist`, `Tools/release.sh` |
| Телеметрия | Только `trial_started`, `activation_requested`, `paywall_shown`; выключатель и раскрытие при первом запуске; никаких content-derived полей | `Services/Telemetry/ProductTelemetryService.swift`, `Service/src/events.js` |
| Серверные события | Отдельно от трёх клиентских событий сервер умеет сообщать trial issued / purchase / renewal / refund в PostHog EU при наличии конфигурации; Windows-клиент не дублирует эти отправки | `Service/src/analytics.js`, `Service/test/analytics.test.mjs`, `docs/PRIVACY.md` |
| Локализация | Английский исходный интерфейс и немецкая локализация; языки интерфейса не равны языкам распознавания | `Resources/Localizable.xcstrings` |

Старые README, `ARCHITECTURE.md`, phase-документы и отдельные комментарии содержат прежние «5 диктовок/24 часа», «14 дней», «события не отправляются», «единственный сохраняемый файл». Они **не определяют** Windows-поведение. Реализации и тесты release baseline приоритетнее исторических описаний и отстающего локального checkout. Privacy-текст брать из release baseline, где уже раскрыты серверные PostHog-события; старую длительность trial дополнительно вычитать.

### Обязательные дополнения после сверки с 0.6.8

- В 0.6.6 была неудачная оптимизация определения языка по первым 1.5 секундам: начальная пауза могла привести к неверному языку и переводу. В 0.6.7 это отменено. Windows не должен возвращать эту регрессию ни как streaming optimization, ни как ранний окончательный language pin.
- В 0.6.8 ускорение получено повторным использованием encoder output при byte-for-byte совпадении mel input, shape, strides и type, только внутри одной записи; cache очищается по окончании/отмене. Для single-language профиля reuse не включается. Переносится требование корректности и устранения лишних вычислений; Core ML-класс не копируется в whisper.cpp буквально.
- В release-исходниках добавлены `Tools/make_leading_silence_corpus.py`, `EncoderOutputReuseTests.swift`, `EncoderReuseParityTests.swift` и результаты в `docs/PHASE_2_BENCHMARK.md`. Приведённые там 120 synthetic samples и ускорение примерно на 0.45 s относятся к Mac/M1 и опубликованному отчёту, а не к измерениям Windows или новому запуску тестов в этом треде.
- В актуальном UI исправлены высота раскрываемой истории и перехват кликов декоративной рамкой (`allowsHitTesting(false)`). В WPF явная высота/ограничение viewport и отсутствие hit testing у декоративных overlays входят в regression checklist.
- Общий сервер брать из актуальной ветки release, не заменять локальной старой копией `Service/`: она не содержит новой server analytics и связанных тестов. Факт наличия кода не доказывает, что секрет PostHog настроен в deployment.

### Обязательная дельта 0.6.9–0.6.14

| Release | Продуктовое изменение | Windows gap перед W9 |
| --- | --- | --- |
| 0.6.9 | Input-only capture, продолжение одной фразы после route/format/device change, channel-0 handling для многоканального входа, нормализованная проверка тихой речи | WASAPI capture уже input-only, но invalidation завершает фразу; route monitor/rebind отсутствуют; 3+ каналов сейчас усредняются; live VAD может отбросить тихую запись |
| 0.6.10 | Прогресс модели по байтам, оставшийся размер и консервативный ETA | Точные completed/total bytes уже есть; UI показывает только процент, rate/remaining/ETA отсутствуют |
| 0.6.11 | Обнаружение Bluetooth input, который отдаёт bit-exact zeros, fallback или более сильный platform-specific claim | Bluetooth-классификация, digital-silence watchdog и Windows-specific recovery отсутствуют |
| 0.6.12 | Checkout через product site и понятный promo-code copy | Намеренно не переносится в закрытую Windows beta до решения commercial terms |
| 0.6.13 | Шесть setup funnel events в дополнение к трём licensing events; once-per-install milestones; payment/refund service fixes | Windows знает только три события и пять полей license record; актуальный `Service/` ещё не интегрирован в Windows-линию |
| 0.6.14 | Не начинать следующую запись с недавно доказанно немой гарнитуры; forwarding product events и promo attribution на service side | Session-only silent-input memory отсутствует; server changes должны прийти из актуальной product line, без дублирования в Windows client |

Критический путь W9 — Windows-specific audio resilience. Поведение macOS задаёт
пользовательский контракт, но AUHAL/VoiceProcessingIO не копируются в Windows.
Нужно воспроизвести случаи на WASAPI/Core Audio Windows, оставить аппаратные
утверждения pending до физического теста и не ослаблять privacy/content lifetime.

## 2. Решения для первой Windows-версии

### Платформа и структура

- Windows 11 x64 на поддерживаемых Microsoft выпусках. Windows 10 и Windows ARM64 не входят в первый заявленный набор совместимости. Минимальный build зафиксировать в W0 после проверки матрицы .NET/SDK.
- Отдельное нативное desktop-приложение: **C# / .NET 10 LTS / WPF**, небольшой C++ слой для WASAPI и whisper.cpp. UI и Win32-адаптеры не переносить на Swift и не переписывать Mac-приложение.
- Core на `net10.0` без WPF/Win32, Windows app/platform на `net10.0-windows`. Core-тесты должны запускаться и на Mac. WPF работает только на Windows; окончательная сборка, native DLL и системные проверки — Windows CI. [WPF](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/overview/), [.NET 10](https://devblogs.microsoft.com/dotnet/announcing-dotnet-10/).
- Приложение запускается как обычный пользователь, один экземпляр. Не требовать admin, службу, драйвер, `uiAccess` или Microsoft Store. UI-состояние — на Dispatcher; запись и inference — вне UI-потока.
- Переиспользуем протоколы, алгоритмы, тестовые сценарии, тексты, branding и сервер. Перенос в C# — реализация той же спецификации, а не утверждение о прямой совместимости Swift-кода.

Предлагаемая раскладка:

```text
Windows/
  AGENTS.md                         # Windows-specific engineering rules
  Witness.Windows.sln
  global.json                       # pinned SDK
  Directory.Build.props
  Directory.Packages.props
  src/Witness.Core/                 # state machine, text, risk, policies
  src/Witness.Platform.Windows/     # Win32, persistence, HTTP, updates
  src/Witness.App/                  # WPF, tray, composition root, resources
  native/Witness.Native/           # C ABI, WASAPI/resampling, whisper adapter
  tests/Witness.Core.Tests/
  tests/Witness.Platform.Tests/
  tests/Witness.UiHarness/          # owned test windows, no user's apps
  tools/                           # build, package, smoke, signing checks
  THIRD_PARTY_NOTICES.md
Shared/Fixtures/WindowsParity/      # artificial, non-user test cases
.github/workflows/windows-ci.yml
.github/workflows/windows-package.yml
```

Точные имена проектов можно упростить, сохранив границы. Не строить общий cross-platform UI-фреймворк и не выносить всё Swift-ядро в C++ ради первой версии.

Корневые требования Swift/Apple Silicon описывают Mac-target. В W0 уточнить их область действия и добавить `Windows/AGENTS.md`, сохранив общие ограничения приватности, лицензирования зависимостей и проверок. Запреты исторической Mac Phase 1 не означают запрет STT и обновлений в Windows W1–W8.

### Зависимости

До добавления каждой зависимости записать точную версию/commit, источник, лицензию, причину необходимости и transitive notices. Не использовать плавающий `latest` при сборке.

| Компонент | Решение и причина |
| --- | --- |
| UI, tray, горячие клавиши, clipboard, HTTP, JSON | WPF, .NET, Win32; стандартных API достаточно. Tray можно сделать через встроенный WinForms `NotifyIcon`, без отдельного UI toolkit |
| Аудио | Windows WASAPI + Media Foundation resampler через небольшой C++ адаптер. Стандартные API покрывают задачу; NAudio/FFmpeg не добавлять по умолчанию. [WASAPI](https://learn.microsoft.com/en-us/windows/win32/coreaudio/wasapi), [resampler](https://learn.microsoft.com/en-us/windows/win32/medfound/audioresampler) |
| STT | `whisper.cpp`, MIT, закреплённый commit, CPU + опциональный Vulkan. Windows и CPU/GPU поддерживаются; точность word timing нужно отдельно проверить. Стандартного API с эквивалентной offline-моделью и метаданными здесь недостаточно. [Upstream](https://github.com/ggml-org/whisper.cpp) |
| Ed25519 | `NSec.Cryptography`, MIT, с notices его libsodium/ISC и остальных компонентов; общий проверенный verifier для LD1 и Windows update manifest, разные публичные ключи. Не писать криптографию самостоятельно. [NSec](https://nsec.rocks/), [лицензии](https://nsec.rocks/license) |
| Installer/updater | `Velopack`, MIT, за адаптером `IAppUpdater`: установка и замена unpackaged приложения без собственного updater-процесса. Подпись собственного каталога проверяем дополнительно, не приравниваем checksum к подписи. [Интеграция](https://docs.velopack.io/integrating/overview), [лицензия](https://raw.githubusercontent.com/velopack/velopack/develop/LICENSE) |
| Тесты | Один закреплённый стандартный .NET test framework, например MSTest; никаких микрофонов/сетевых сервисов в unit-тестах |

В W0 подтвердить, что выбранная версия Velopack позволяет весь путь проверки до извлечения/установки через `IUpdateSource`. Это технический критерий выбора зависимости. Не удалять проверку подписи, чтобы подогнать её под SDK.

### Модель и аппаратные ожидания

- Начальная кандидатура: multilingual Whisper large-v3-turbo, Windows-совместимый формат ggml, quantized-вариант как кандидат. Точные artifact, размер, SHA-256 и лицензию закрепить после smoke-проверки. Core ML-веса Mac не подходят; не переносить обещание «600 MB» в Windows UI.
- CPU — обязательный работоспособный fallback. Vulkan — дополнительное ускорение на поддерживаемом устройстве; отсутствие Vulkan loader/драйвера не должно ломать старт CPU-версии. CUDA-only и отдельная NVIDIA-сборка пока не нужны.
- До физических тестов 16 GB RAM — рекомендованная стартовая конфигурация тестирования, не доказанный минимум. Проверить 8 GB отдельно. Не обещать real-time или ускорение на любой GPU.
- Движок получает PCM из памяти, возвращает raw text, диапазоны, временные отметки, вероятности и язык. Никаких временных WAV, запуска CLI через файлы, локального HTTP-сервера или remote fallback.
- Слабый компьютер получает честное описание скорости/ошибки. Нельзя незаметно заменить multilingual-модель на English-only либо отправить запись в облако.

## 3. Архитектурные контракты и сложные места

### Состояния, запись и языки

Сохранить состояние `launching → permission/ready → starting → recording → finishing → transcribing → inserting → ready/locked`, ошибки и recovery. License gate проверяется до открытия микрофона; истечение лицензии не отнимает уже записанную фразу. Отмена STT/insertion и номер поколения не позволяют позднему callback вставить предыдущую диктовку.

Протоколы: `IHotkeyService`, `IMicrophoneAccess`, `IAudioCapture`, `IVoiceActivityDetector`, `ITranscriptionService`, `ICleanupService`, `ILexiconChecker`, `ITextInsertionService`, `IClipboard`, `IFragmentPlayer`, `IPreferencesStore`, `IEntitlementStore`, `IActivationBackend`, `IAppUpdater`. Время, файловая система и HTTP транспорта инъецируются там, где от них зависит политика.

Горячая клавиша по умолчанию — кандидат `Ctrl+Shift+Space`, с обнаружением конфликта и изменением пользователем. Не переносить `Alt+Space`: у Windows другое назначение. `RegisterHotKey` с `MOD_NOREPEAT` даёт активацию, но для hold-to-talk отдельно нужен key-up: короткий опрос только участвующих клавиш через `GetAsyncKeyState` на время активного удержания; тест на отпускание модификатора первым. При блокировке сессии/потере desktop завершить захват. Не добавлять журнал нажатий или глобальный перехват всего ввода. [RegisterHotKey](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey).

WASAPI shared/event-driven capture: поток считывания быстро освобождает системный буфер и передаёт данные через ограниченный буфер; resampling/VAD/inference не блокируют его. Нормализация 44.1/48 kHz, PCM16/24/32/float, mono/stereo → 16 kHz mono float; корректный flush хвоста конвертера. Переполнение и discontinuity — явный результат, не тихая потеря слов. C ABI с явным владением памятью, `SafeHandle` и освобождением при отмене; исключения C++ не пересекают ABI.

Сохранять endpoint ID конкретного микрофона, не отображаемое имя. Встроенный микрофон распознавать по достоверным метаданным, не по строке имени; если отличить его нельзя, использовать системный input и назвать фактический выбор. Windows desktop-доступ к микрофону отличается от macOS: не рисовать фиктивный per-app permission prompt, обрабатывать access denied и ссылку на системную privacy-настройку.

Каталог поддерживаемых языков сверить с выбранной моделью. Port `LanguageDecision`: выбранное подмножество, порядок предпочтения, margin 0.2, предыдущий язык с TTL 120 секунд и временный pin. Финальное определение языка использует завершённую запись с обычным полным окном движка, а не короткий префикс во время записи. Decode всегда `transcribe`, не `translate`, выбранный язык фиксируется явно. Параметры движка и способ сборки token→word проверять, а не объявлять идентичными WhisperKit.

Проверить, повторяет ли выбранный whisper.cpp API encoder для detection и decode. Если повторяет — изучить безопасное переиспользование внутри одной операции, с проверенным совпадением входа/параметров и очисткой при отмене/завершении. Если API уже устраняет повтор, не добавлять второй cache. Если для устранения нужен рискованный fork движка, сначала оставить корректный путь и явно записать performance gap; нельзя ради скорости сократить аудио для определения языка. Оптимизация сравнивается с отключённой на одном Windows backend/model: язык, текст, tokens/timing/confidence должны совпадать, между записями никакие audio-derived tensors не сохраняются. Не требовать побитового равенства WhisperKit и whisper.cpp — это разные движки.

### Unicode и проверка текста

Swift хранит диапазоны как offsets по `Character` (grapheme clusters), C# string — UTF-16, whisper.cpp — UTF-8. Нужен **один** адаптер индексов. Domain/fixtures сохраняют grapheme offsets; UI/Win32 используют преобразование в UTF-16. Тесты: кириллица, `ї/є/ґ`, umlaut, combining marks, emoji/surrogates, апострофы, повторяющиеся слова, CRLF, CJK. Нельзя искать каждое слово первым `IndexOf` и получать неправильную подсветку повторов.

Тайминги допускают реальную гранулярность движка. При отсутствии word timing показывать/проигрывать сегмент с явной гранулярностью, не выдумывать точные отметки. Confidence сохранять для измерений, но его вес остаётся нулём до отдельной калибровки.

Port очистки, risk weights и обеих review-политик с одинаковыми входными/выходными fixtures. DE/EN/RU/UK — набор существующих правил, **не автоматическое доказательство Windows-качества**. Для остальных языков оставить recognition и только действительно language-independent проверки согласно текущему коду, без включения некалиброванных словарных/языковых эвристик.

Для системного словаря использовать Windows Spell Checking API и `IsSupported`. Отсутствие словаря — «сигнал недоступен», а не «все слова ошибочны»; отключить только зависящий от него сигнал и показать ограничение локально. Если RU/UK не доступны на чистой машине, это отдельный пункт QA, а не основание незаметно объявить полную проверку. Не добавлять словари с невыясненной лицензией. [API](https://learn.microsoft.com/en-us/windows/win32/api/spellcheck/nf-spellcheck-ispellcheckerfactory-issupported).

### Вставка и clipboard

Самая важная интеграция после аудио. Прямой перенос macOS Accessibility-механики на UI Automation невозможен.

1. В начале записи запомнить PID и top-level HWND назначения. Непосредственно перед каждым side effect повторно проверить foreground, сессию, protected state и отмену. Не делать `SetForegroundWindow` для насильственного возврата. Windows-консервативное отличие: смена top-level окна тоже считается сменой назначения; движение каретки внутри прежнего окна допустимо.
2. UI Automation используется для `IsPassword`, сведений о selection/caret и локальной проверки результата. Не использовать `ValuePattern.SetValue` как общий insert-at-caret: это может заменить весь документ. Прямой путь разрешён только для известного контрола с корректной семантикой замены selection; остальное — paste.
3. Не считать `SendInput` доказательством вставки: он подтверждает отправку событий. Учитывать UIPI и не пытаться обойти elevated-приложение запуском Witness администратором. [Ограничения SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput).
4. Дождаться отпускания модификаторов горячей клавиши, с ограниченным ожиданием, затем единая последовательность Ctrl+V. Не генерировать Enter/отправку сообщения. Не делать второй paste по таймауту: первый может ещё прийти.
5. Clipboard snapshot — временный, best-effort для обычного текста. Restore только после подтверждённой вставки именно текущей диктовки и если `GetClipboardSequenceNumber` не изменился посторонним действием. При unverified paste оставить новый текст и соответствующее сообщение; не возвращать старую диктовку по фиксированному таймеру.
6. Для каждого помещения текста Witness в clipboard, включая copy из истории/review, ставить Windows-форматы запрета Cloud Clipboard/history. Это конкретная часть local-first обещания: `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory=0`, `CanUploadToCloudClipboard=0`. При невозможности установить защитные форматы не выполнять обычный незащищённый fallback. [Microsoft](https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-formats#cloud-clipboard-and-clipboard-history-formats).
7. Password/UAC/locked desktop: ни вставки, ни автоматического копирования, ни записи в copy history. У Windows нет точного аналога глобального macOS secure-input; не имитировать его несуществующими гарантиями. Если безопасность поля неизвестна или UIA зависла, результат остаётся внутри Witness, автоматический paste/copy не выполняется; для обычного неопределённого поля возможна явная пользовательская команда копирования. Известное защищённое поле не получает такой автоматический обход.
8. Смена назначения → clipboard fallback лишь после проверки текущего контекста на protected/unknown; при сомнении оставить результат внутри приложения. Любые чтения поля и clipboard остаются в RAM и не входят ни в логи, ни в события.

COM/UIA-вызовы изолировать от UI и capture, ограничивать по времени. Не создавать новый неограниченный worker на каждый зависший вызов. В W4 проверить механизм отмены/ограничения UIA; при необходимости изолировать только этот адаптер в локальный helper с защищённым IPC. Не строить helper заранее без подтверждённой необходимости.

### Интерфейс и локальные данные

Переносить узнаваемое оформление Witness и существующие сценарии, использовать WPF controls/resources и системные шрифты. Не затевать редизайн. Окна onboarding/settings/paywall могут получать фокус по действию пользователя; activity badge и автоматическое появление review-индикатора — нет.

- Tray: состояние, язык на сессию, последняя диктовка/10 recent copies, review, настройки, выход.
- Onboarding: языки, понятное состояние микрофона, загрузка модели с размером/progress/retry, раскрытие трёх событий. Без требования macOS Accessibility.
- Settings: текущие шесть разделов, включая ручные updates, microphone, privacy, startup. Настройки и glossary мигрируются атомарно, повреждение файла восстанавливается без потери лицензии в соседнем файле.
- Badge: recording/processing, click-through и no-activate; позиция около caret, fallback около указателя, clamp к рабочей области текущего монитора; не вставлять placeholder в чужой документ.
- Review: raw/cleaned, отмеченные фрагменты, ограниченный replay, копирование; новые результаты не редактируют уже вставленную фразу молча. Audio освобождается по текущей политике, recent history не удерживает записи.
- EN/DE интерфейс; извлечение проверенных строк из `.xcstrings` в `.resx`, корректные placeholders/plurals, новые Windows-сообщения тоже переводятся. Speech language не переключает UI language.
- Keyboard-only навигация, видимый focus, Narrator labels, high contrast, 100/125/150/200% DPI, несколько мониторов, уменьшенная анимация. Эти критерии следуют WPF guidance `ui-ux-pro-max`; глобальный hotkey реализуется отдельно от оконных `InputBindings`.
- `%LocalAppData%/Witness/`: preferences, glossary, license record, Models и локальные технические данные. Установка Velopack получает другой pack ID/каталог, например `Witness.Windows`, чтобы обновление/удаление бинарников не удаляло данные. Развести Beta/Stable app IDs и каталоги.
- Временная история — максимум 10 текстов; transcript, audio, clipboard snapshots не сериализуются и не попадают в crash/log export. OS paging/crash policies не контролируются полностью: обещать отсутствие записи приложением, не невозможность любых следов в ОС.

### Лицензия, сервер и приватность

Сохранить `LD1.<payload>.<signature>` и проверять подпись над **декодированными исходными payload bytes**, не повторной сериализацией JSON. Использовать `Service/fixtures/parity.json`, включая тесты неправильной подписи/устройства/дат. Unix seconds серверного payload не путать с форматом локальных Swift JSON dates.

Activation остаётся `POST /v1/activate` с **ровно** `device` и `email`; release — существующий контракт `/v1/devices/release`. HTTPS, `User-Agent: Witness`, без cookies/content/автоматического call-home. Annual/trial expiry и offline verification повторяют текущие правила. Удаление локального ключа и освобождение server slot — разные исходы при сетевой ошибке; переносить из `EntitlementService` и тестов.

Windows device ID: отдельная namespace-соль, нормализованный SMBIOS UUID через системный API; SHA-256, первые 16 байт → 32 lowercase hex. Raw UUID не сохраняется и не отправляется. Проверить placeholders/нулевой UUID. При недоступной идентичности — понятное состояние активации, не общий `unavailable` hash для всех ПК и не новый случайный device ID на каждом запуске. Upgrade приложения не меняет ID; замена платы/переустановка ОС и политика fallback фиксируются тестами и документацией.

Сервер уже принимает opaque 32-hex device, не требует OS в activation body. Для первой беты реализовать production-compatible adapter, но повседневные CI/tests используют fake transport и тестовый authority. Закрытая beta сборка — с отдельным beta authority и выдаваемыми разработчиком ключами; не вшивать приватный ключ или публично известный fixture seed в распространяемый issuer. Получение тестового device ID не даёт production-лицензию.

Коммерческое предложение для Windows ещё не определено. Предлагаемый минимум для публичного запуска — одна лицензия с общим лимитом 2 компьютера Mac/Windows, без новой модели биллинга; **это предложение, не уже обещанное право покупателей**. До подтверждения условий beta не открывает существующие Mac-only payment links. Полностью реализовать paywall/consent/browser checkout за конфигурацией, проверить на stub URL. Изменения mailer, checkout-текстов и сайта подготовить отдельно до продаж, не публиковать как часть технического переноса.

В W6 клиентская телеметрия была реализована с исходными тремя событиями и тем
же opt-out. W9 расширяет fixed enum до девяти передаваемых событий 0.6.14,
добавляя только `installed`, `model_download_started`, `model_ready`,
`model_failed`, `dictation_blocked_by_model` и `microphone_denied`. Не добавлять
usage/content/performance analytics. Setup milestones отправляются не чаще
одного раза на install и сохраняются в существующем allowlisted license record,
а не в новом usage-log файле. У beta транспорт по умолчанию local-only, чтобы не
смешивать тесты с production-воронкой. Для любой реальной отправки сначала
раскрыть Windows-значения `system_version`, получателя/retention и PostHog
processing в документах. Уже существующие server-side purchase/refund events
идут отдельным путём и не дублируются Windows-клиентом. Consent читается перед
каждой отправкой; нет очереди, retry-файла или content-derived полей. Изменения
`Service/` требуют `npm test`, а изменение выдаваемых ключей — также
`npm run fixture` и Swift/C# parity suites.

## 4. Ручные подписанные обновления — обязательная часть беты

Сценарий: **Settings → Check → описание версии → Download/Install по подтверждению → безопасный restart**. Ошибки обновления не отключают диктовку. Update service живёт дольше окна Settings.

Два независимых механизма доверия: Windows code signing для исполняемых файлов и Ed25519-подпись update metadata, связывающая точный пакет с версией. HTTPS/публичный GitHub release/SHA-256 сами по себе не заменяют подпись каталога. Windows update signing key отделён от license authority и Sparkle key; секреты только в предназначенном для signing хранилище/CI secrets.

Предлагаемый signed envelope: версия схемы, key ID и base64 исходных manifest bytes плюс Ed25519 signature. Подписанный manifest задаёт platform, architecture, channel, version/build, release URL, размер, SHA-256 полного пакета, minimum OS, product major и release notes. Проверять подпись **до доверия к этим полям**, затем лимиты, версию/канал/архитектуру, URL/redirect policy и hash пакета. Ключ не берётся из скачанного manifest; rotation требует доверенного перехода. Точную схему и ограничения закрепить fixtures в W0.

Реализация:

- `IAppUpdater`: `Idle`, `Checking`, `UpToDate`, `Available`, `Downloading`, `ReadyToInstall`, `Installing`, `Failed`; повторный клик не запускает вторую операцию.
- Velopack startup hook вызывается до обычного запуска UI. Явно выключить `SetAutoApplyOnStartup(false)`: у SDK применение ранее скачанного update при старте включено по умолчанию. Не вызывать check при launch, таймере, закрытии Settings или восстановлении сети. [Startup/update API](https://docs.velopack.io/integrating/overview).
- Свой verified `IUpdateSource` допускает только package из проверенного manifest; release notes — обычный текст без исполняемого HTML. В первой версии только full packages, без delta complexity. Проверку пакета завершить до передачи SDK на извлечение/установку. [Update sources](https://docs.velopack.io/integrating/update-sources).
- Отмена/обрыв скачивания, restart приложения с pending package и повторная проверка не приводят к установке без подтверждения. Перед apply снова сверить пакет/manifest. Не обрывать recording, STT, insertion или replay: предложить повторить после завершения; не планировать принудительный таймер завершения.
- Lifetime: обновлять автоматически выбранным предложением только внутри покрываемой major. Отдельно лицензируемую major не ставить поверх рабочей копии; старый канал продолжает существовать. Проверку entitlement выполнить также непосредственно перед apply.
- Beta и Stable имеют отдельные app IDs, authority/feed/config; каналы привязаны к Windows x64 и major. Stable не видит beta/downgrade/другую архитектуру.
- Каталог приложения, Models и пользовательские данные раздельны. Проверить update A→B с сохранением настроек, воспроизводимой device identity, лицензии и неизменившегося model artifact. Session glossary не сохранять даже ради update: vocabulary остаётся RAM-only и очищается при необходимом restart.
- Установщик/updater/app подписывать через Windows code-signing pipeline с timestamp; сертификат выбрать до внешней раздачи. SDK помогает подписывать Setup/Update binaries, но факт подписи ещё не гарантирует отсутствие предупреждения SmartScreen. [Velopack signing](https://docs.velopack.io/packaging/signing).
- Перечислить в Windows privacy: feed/package hosts и redirects/CDN, IP/URL/User-Agent, цель, хранение metadata у провайдера, локальный update cache/logs. Никаких ключей лицензии, email, device ID или контента в update URL/headers. Различать network activity приложения и системную проверку сертификатов Windows.

**Не сломать Mac distribution.** Нынешние `SUFeedURL` и download-ссылка используют `/releases/latest/download/appcast.xml` и `Witness.dmg`. Windows-only release, назначенный latest в том же репозитории, сделает их недоступными. Базовое решение: отдельный repository/feed для Windows-дистрибутива; beta до его подготовки — CI artifacts/local test feed. Если общий release repository необходим, Windows-релизы не менять на latest, а Windows feed закрепить на собственном канале; доказать отдельным release-check, что обе Mac-ссылки сохраняются. Один флаг или надежда на сортировку тегов не заменяют проверку.

## 5. Порядок реализации

Работать последовательными срезами, обновляя `Windows/IMPLEMENTATION_STATUS.md`: код, выполненные команды, результат, CI run/artifact, известные ограничения, следующий шаг. Незавершённую фазу не обозначать completed. В конце каждой фазы должны оставаться собираемые проекты и осмысленные тесты.

### W0 — закрепить основу и убрать технические неизвестные

- Проверить latest опубликованный Mac release, его tag/commit и отличия рабочего дерева; сохранить таблицу parity и baseline hashes ключевых release-исходников в status/manifest. Минимальная подтверждённая основа — 0.6.8/build 9, не локальная 0.6.2. Read-only baseline через Git objects не требует коммита чужих правок.
- Уточнить Windows scope в `AGENTS.md`, закрепить SDK/Windows SDK/native toolchain/dependency versions и лицензии.
- Создать solution, Core unit-test target и Windows build CI; паковать self-contained runtime, без требования .NET/Visual Studio у тестировщика.
- Выполнить маленький native smoke: PCM в RAM → whisper CPU → текст/тайминги; подтвердить CPU-запуск без Vulkan DLL. Отдельно прототип signed manifest → verified update source на двух искусственных версиях.
- Сформировать Windows-specific privacy/endpoint inventory и source of truth для build/channel/model metadata.

**Выход:** воспроизводимая сборка Windows CI, простой исполняемый shell и отчёт о двух spikes. При проблеме со словесными таймингами/подписью updater сначала исправить контракт, не маскировать проблему фейковыми данными. Отсутствие физической Windows не блокирует остальные фазы.

### W1 — чистая логика и parity

- Перенести модели/state machine, VAD и bounds, language choice/pin, Unicode offsets, cleanup/edit map, risk/review policies, entitlement/lifetime policies.
- Сделать искусственные fixtures из существующих детерминированных тестов, с ожидаемыми результатами от Swift-референса. Явно учитывать лексикон как dependency, не смешивать его результат с чистой логикой.
- Перенести ключевые regression cases: locked→locked, пустая диктовка, expiry во время записи, отмена поколения, два порога, имена/даты, unverified languages.

**Выход:** Core tests проходят на Mac и Windows; parity не расходится по чистым алгоритмам. Минимум — покрыты все перечисленные контракты, а не достигнуто произвольное число тестов.

### W2 — tray, горячие клавиши, запись и микрофоны

- WPF lifecycle/tray/single-instance; hotkey hold/toggle/change/conflict; startup opt-in и обработка system disable.
- WASAPI capture, нормализация, VAD, остановка по max duration, device selection/fallback, запреты микрофона и сохранение фразы при disconnect.
- Activity badge и честные empty/no-speech/interruption состояния.

**Выход:** fake audio lifecycle и native conversion tests проходят; audio pipeline не пишет на диск, buffers bounded. Микрофонный тест CI не выдавать за физический тест.

### W3 — локальная модель и транскрипция

- Model manager: автоматическая первая загрузка с disclosure, единственная download/load task, progress/cancel/retry, атомарное завершение, SHA-256, нехватка места, corrupt/partial files, offline reuse.
- In-process whisper.cpp adapter с token/word mapping, выбранными языками, pin, abort/cancellation, ограниченным выполнением, CPU fallback; не держать несколько копий модели при повторных кликах.
- Языковая регрессия 0.6.6: тесты mixed profiles с 0.5/1.0/1.5/2.5 s начального тихого шума, особенно RU/UK/EN. Окончательный выбор языка после записи; не переводить текст вместо транскрипции. Encoder reuse исследовать по контракту 0.6.8 и доказать parity on/off на том же Windows движке; cache не переживает запись. Если backend не позволяет reuse, зафиксировать ограничение отдельно от функциональной готовности.
- Vulkan backend должен загружаться опционально; проверять поддержку операций/инициализации, не только наличие названия GPU. Backend failure не возвращает ложный пустой transcript; один контролируемый CPU retry только для ещё актуальной операции.
- Подготовить CLI benchmark harness, использующий тот же адаптер и только специально созданные тестовые fixtures; он не является продуктовым file-dictation feature.

**Выход:** установленная модель работает при отключённой сети; synthetic smoke на DE/EN/RU/UK выполняется в CI, report честно отделяет CI CPU от будущих измерений ноутбуков.

### W4 — безопасная вставка

- Реализовать target/protected checks, UIA adapter, modifier wait, clipboard protection/restore, verified/unverified outcomes и cancellation races.
- Создать собственные простое text field, password field и delayed-paste harness для автоматических проверок. Fake adapters — для недоступных/elevated/unknown случаев.
- В тестах доказать отсутствие повторной вставки, вставки в сменившееся окно, старого текста после restore и перезаписи clipboard, изменённого пользователем.

**Выход:** все правила раздела 3 проверены детерминированно; реальные Word/Chrome/VS Code пока помечены pending. Никаких утверждений «работает во всех приложениях».

### W5 — review, история и полный пользовательский путь

- Подключить cleanup/risk, Windows lexicon capabilities, attention indicator, raw recovery/replay и release audio.
- Довести onboarding, все шесть разделов Settings, glossary, recent 10 с видимым раскрываемым/прокручиваемым viewport, audio input UI и EN/DE resources; декоративные границы не перехватывают клики.
- Проверить layouts/DPI/keyboard на owned UI harness; данные пользовательского сеанса не попадают в автоскриншоты.

**Выход:** полный путь hotkey→capture→STT→insert→optional review; история ограничена, защищённые случаи её не пополняют, quiet results освобождают аудио. Есть изображения ключевых UI состояний с искусственными данными.

### W6 — лицензирование и разрешённая сеть

- LD1 verifier и Service fixture parity; Windows identity; 3+10-day policies, annual/lifetime, warning/paywall, consent, release slot, restart/offline.
- Production-compatible HTTP adapters + тестовые endpoints через dependency injection; release-конфигурация не принимает произвольный URL через пользовательские настройки.
- Исходные три события, opt-out, beta local-only; точные allowlists сетевых полей и запрет content во всех network bodies/URLs/logs. Расширение до девяти событий 0.6.14 выполняется отдельно в W9.
- Windows privacy/terms changes подготовлены как черновик, отличия Mac-only commercial wording обозначены.

**Выход:** тесты проходят без production-вызовов; beta имеет контролируемый механизм тестовой лицензии. Ожидание коммерческого решения не блокирует разработку.

### W7 — установка и обновления

- Velopack packaging, отдельные feed/app IDs, подпись manifest/packages, ручной `IAppUpdater` и UX ошибок.
- CI строит A и B: install A, сохранение искусственных settings/license/model, check/download/apply B, restart и проверка сохранности; session glossary после restart обязан быть пустым и не иметь handoff-файла; отдельно tampered feed/package, неверный key/channel/arch, downgrade, не покрываемая major.
- Отключить auto-apply-on-startup и доказать отсутствие запроса/установки без пользовательского действия. Попытка update во время записи не теряет фразу.
- Install/uninstall/reinstall проверки; политика удаления локальных данных обозначена, uninstall не вызывает remote slot release самовольно.

**Выход:** установщик и реально проверенный update A→B в доступной CI-среде. При отсутствии signing credentials — unsigned internal artifact + явно незакрытый signing gate; не имитировать production signature и не объявлять signed release готовым.

### W8 — подготовка закрытой беты для внешнего QA

- Собрать Release/Beta installer, checksum, notices, release notes, known issues, guide на EN, чек-лист и bug-report template.
- Зафиксировать комплект тестовых фраз DE/EN/RU/UK без персональных данных, задания для CPU/GPU/microphones и две версии для проверки обновлений.
- Выполнить CI/regression/soak/privacy checks; все оставшиеся физические проверки перечислить как pending.
- Указать точные machine/build/model/backend сведения, которые тестировщик заполняет вручную; локальные timing metrics не отправляются автоматически.

**Выход:** комплект, с которым пользователь может заказать тестирование без дополнительной разработки тестового инструментария. Контакт с исполнителями и заказ тестирования — последующее действие пользователя.

### W9 — догоняющее обновление до Witness 0.6.14

W9 выполняется последовательными рабочими срезами. Каждый срез заканчивается
детерминированными тестами, clean build и обновлением implementation status.

#### W9.0 — интегрировать продуктовую линию и закрепить новый baseline

- Интегрировать `v0.6.14`/актуальный `main` с Windows-линией, сохранив весь
  Windows implementation и не возвращая старые Mac/Service файлы.
- Разобрать каждый конфликт по контракту, а не выбором одной стороны целиком.
- Обновить Mac baseline metadata/hashes до 0.6.14 build 15 только после
  успешной интеграции. Windows beta version `0.1.0` не менять без отдельного
  решения о versioning.
- Прогнать `npm test` для пришедшего `Service/`; `npm run fixture` нужен только
  если интеграция меняет то, что сервис выдаёт в license fixture.

**Выход:** одна собираемая линия содержит актуальные Mac/Service исходники и
Windows client; baseline 0.6.14 подтверждён точными Git metadata и hashes.

#### W9.1 — многоканальный вход и честная тихая речь

- Для 3+ interleaved каналов не усреднять все каналы без измерения: закрепить
  channel-0 policy тестами с сигналом только в channel 0 и только в остальных
  каналах; mono/stereo поведение не менять без доказанной причины.
- Сохранять bounded PCM до окончательной оценки; если live VAD не нашёл речь,
  выполнить off-audio-thread gain-normalized VAD pass с жёстким gain cap.
  Нормализация отвечает только на вопрос «была ли речь» и не должна тихо
  переписывать samples, поданные в STT, без отдельного corpus measurement.
- Добавить deterministic conversion/VAD tests для тишины, очень тихой речи,
  multi-channel phase cancellation и maximum-duration bounds.

**Выход:** тихая реальная речь не превращается автоматически в `NoSpeech`, а
многоканальный input не обнуляется усреднением каналов.

#### W9.2 — продолжение одной фразы при изменении аудиомаршрута

- Разделить lifetime фразы (PCM buffer, VAD, generation) и lifetime одного
  WASAPI input segment (endpoint, client, format, worker).
- Добавить Core Audio notification adapter для default endpoint/list changes,
  обработку device invalidation/format change и watchdog отсутствующих packets.
- Debounce bursts; re-resolve selection; stop/drain старый segment и открыть
  новый в ту же фразу. Использовать bounded retry budget и завершать с
  interruption только когда вход не восстановился.
- Смена default следует новому endpoint только для `SystemDefault`; specific и
  built-in selection не должны флапать обратно посреди фразы.
- Не выполнять COM/reopen работу в real-time callback и не блокировать WPF
  Dispatcher.

**Выход:** synthetic segment-splice и race tests доказывают одну фразу, один
VAD/buffer и отсутствие stale callback после rebind; MSVC/Windows CI проходит.

#### W9.3 — silent Bluetooth headset и защита первого слова

- Расширить capability adapter проверяемой Windows-классификацией Bluetooth,
  не угадывая по friendly name.
- Для Bluetooth segment отслеживать «с открытия были только exact zeros» и
  после измеренного порога переходить на доступный fallback microphone.
- Если другого входа нет, сначала исследовать на физическом Windows 11
  platform-specific communication-mode recovery; macOS VoiceProcessingIO не
  считать готовым Windows-решением.
- Запомнить доказанно немой endpoint только в RAM примерно на 30 минут. Снять
  verdict при исчезновении/reconnect endpoint, смене default или expiry. Новая
  запись сразу выбирает fallback, чтобы не терять первое слово повторно.

**Выход:** pure policy tests покрывают remember/avoid/expiry/reconnect; CI не
делает hardware claim, а physical QA отдельно проверяет PC+phone headset case.

#### W9.4 — прогресс подготовки модели

- Переиспользовать уже имеющиеся точные completed/total bytes; не добавлять
  новый metadata request.
- Добавить clock-injected smoothed transfer rate, warm-up и stall floor;
  показывать оставшийся размер и округлённый ETA только когда он достоверен.
- Сохранить cancel/retry/hash/atomic commit и EN/DE resource parity.

**Выход:** UI показывает процент, остаток и консервативное время либо честно не
показывает ETA; rate tests не зависят от сети и времени машины.

#### W9.5 — setup funnel и актуальный service contract

- Расширить typed telemetry allowlist с трёх до девяти передаваемых событий,
  сохранив те же пять wire fields и fixed qualifiers.
- Подключить call sites к install, model download/ready/failure, press during
  model wait и microphone denial. Классифицировать model failure только как
  `network`, `storage` или `other`, не парся пользовательский текст ошибки.
- Добавить backward-compatible `reportedMilestones` в существующий atomic
  license record. Сначала сохранять milestone, затем делать одну best-effort
  отправку; без retry queue и отдельного usage log.
- Beta transport остаётся local-only, пока не заполнены privacy/legal recipient,
  retention, region и PostHog disclosure. Checkout остаётся disabled.

**Выход:** Core/platform/privacy tests доказывают once-per-install, consent,
точный event/qualifier allowlist, миграцию старого record и отсутствие content.

#### W9.6 — закрыть parity и обновить beta evidence

- Обновить EN/DE strings, release notes, known issues, tester guide, QA checklist,
  privacy inventory, build info и W8 kit expectations.
- Добавить QA cases: default-device switch mid-sentence, unplug/reconnect,
  format change, stalled callback, shared Bluetooth headset with phone, two
  consecutive presses after digital silence, quiet multi-channel input, model
  ETA и once-per-install events.
- Прогнать полный Windows CI, package/privacy checks и новый A→B preservation
  сценарий. Затем повторить физическую microphone/accessibility/performance QA.

**Выход:** Windows status честно говорит «parity baseline 0.6.14» только после
всех автоматических гейтов; hardware claims появляются только из физического QA.

Зависимости фаз: W0 → W1 → W2 → W3 → W4 → W5 → W6 → W7 → W8 → W9.
W9 можно реализовывать до закрытия внешних signing/legal/hardware гейтов W5–W8,
но после W9 соответствующие CI/package и физические проверки выполняются заново.

## 6. Проверки без своей Windows

| Среда | Что подтверждает | Чего не подтверждает |
| --- | --- | --- |
| Mac + .NET | Core/unit/parity, чистые политики, JSON/crypto при поддержке dependency | WPF, Win32, микрофон Windows |
| GitHub-hosted Windows x64 | MSBuild/CMake/package, unit/native/HTTP tests, synthetic CPU inference, файловые/installer/update сценарии | Реальные драйверы, качество микрофона, GPU, UX Windows 11 обычного пользователя |
| Интерактивный UI harness в Windows CI, если доступен desktop | Собственные окна, focus, fake hotkey/input, screenshots, controlled paste | Произвольные приложения и обычная пользовательская сессия на ноутбуке |
| Физические ПК тестировщиков после W8 | Windows 11, реальные устройства, CPU/GPU latency, Word/browser/Electron, SmartScreen, sleep/wake | Все возможные компьютеры и абсолютную гарантию качества |

[GitHub предоставляет Windows runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners). Закрепить конкретный подходящий image вместо плавающего `windows-latest`, проверить его ОС; x64 hosted image может быть Windows Server. Admin/UAC-disabled CI не доказывает работу standard-user/UIPI на Windows 11. Если desktop отсутствует, UI-тест помечается skipped/pending с причиной, а не зелёным «проверено». Это не повод просить пользователя установить VM.

CI правила:

- PR jobs: locked restore, Core/native/platform tests, build; credentials-free. Integration STT job отдельно от быстрых unit, model cache по artifact hash.
- Packaging job: self-contained x64, native runtimes и модельный manifest; release signing через защищённое окружение, недоступное PR коду. Actions и инструменты закреплены версиями/commit SHA.
- Загружать только installer, checksums, технические summaries и UI скриншоты искусственных сценариев. Не загружать записи, реальные транскрипты, clipboard, vocabulary, application contents, crash dumps или content-derived debug traces.
- Test PCM/тексты только специально созданные искусственные данные; аудио smoke генерировать внутри test environment или использовать явно предназначенный redistributable test fixture. Не переносить личный speech corpus на hosted runner. Product logging остаётся без содержания даже в benchmark mode.
- Windows changes → Windows build/tests после среза. Изменения Mac/shared Swift → `xcodebuild` по корневому правилу; Service → `npm test`, ключи → fixture parity. Для изолированного Windows/doc изменения не запускать бессмысленный полный Mac build.
- Если у следующего треда нет доступа к remote/Actions, всё равно подготовить workflows/локальные Core проверки, затем назвать точную недостающую возможность. Наличие YAML без выполненного CI run не означает прошедшую Windows-сборку.

Минимальные suites: state transitions/races; VAD/buffer/conversion; Unicode/edit map; language clamp/pin; risk/prose false-warning regressions; protected insertion/clipboard races; settings/history/audio lifetime; LD1/HTTP/privacy allowlists; updater tampering/no-auto-install/major gate; install/update preservation.

Synthetic speech доказывает исправность pipeline, но не точность на настоящей речи. Обязательно включить leading-silence corpus из release baseline: прежний smoke с речью с нулевого семпла пропустил дефект 0.6.6. На закреплённом языковом regression corpus требовать ноль неправильных language choices; обнаруженные различия whisper.cpp не прятать снижением ожиданий, а разобрать до заявления parity. Для pure prose перенести действующие bounds из `ProseWarningDensityTests` и related tests; не переписывать ожидаемые значения ради зелёного теста. Отдельно считать WER/CER, critical errors, false warnings и p50/p95 latency по языкам, модели и backend; реальные показатели появятся после QA.

## 7. Критерии завершения и пакет для тестировщиков

**Beta-ready после W9 и закрытия внешних гейтов:**

- [ ] Функциональность baseline 0.6.14 и обязательная дельта W9 реализованы либо имеют явно названное platform-ограничение, без потерянных обязательных функций.
- [ ] Есть прошедший Windows build/test run и устанавливаемый self-contained x64 artifact, SHA-256 и точный source revision.
- [ ] CPU путь запускается без GPU SDK; реальные CPU/GPU performance ещё не заявляются.
- [ ] Доказаны RAM-only lifecycle, ограниченные буферы, отсутствие content в persistence/network/logs, запрет Windows clipboard sync/history.
- [ ] Check for updates работает вручную, подпись metadata проверяется, A→B сохраняет данные, Mac latest feed не меняется.
- [ ] EN/DE UI, действующие микрофон/языки/настройки/словарь/история/review, тестовая активация.
- [ ] Тестировщику не нужны Visual Studio, Python, .NET SDK или ручная сборка whisper.cpp.
- [ ] Есть known issues, checklist, bug template и disclosure тестовой подписи/SmartScreen; signing gate отмечен честно. Предпочтительно подписать beta до передачи сторонним тестировщикам.

Предлагаемые артефакты W8:

```text
Witness-Windows-Beta-<version>-x64-Setup.exe
SHA256SUMS.txt
THIRD_PARTY_NOTICES.txt
Windows/TESTER_GUIDE.md
Windows/QA_CHECKLIST.md
Windows/BUG_REPORT_TEMPLATE.md
Windows/KNOWN_ISSUES.md
Windows/IMPLEMENTATION_STATUS.md
```

Внешняя QA-матрица после реализации:

- Intel + integrated graphics, AMD + integrated graphics, NVIDIA laptop/desktop; 16 GB основной набор, 8 GB отдельная проверка ограничений. Не обещать полный hardware coverage по трём машинам.
- Встроенный/USB/Bluetooth микрофон; denied access, unplug/reconnect и смена default device mid-sentence, format/session invalidation, stalled input, тихий многоканальный input, гарнитура одновременно с телефоном, два последовательных старта после digital silence, sleep/wake, повторные короткие и 5-минутные диктовки.
- Notepad, Word, Chrome/Edge textarea и contenteditable, VS Code, desktop messenger; password, elevated app, смена окна, удерживаемые modifiers, clipboard contention и повторная диктовка до конца paste.
- EN/DE/RU/UK, короткие фразы, смешанный набор языков, числа/даты/отрицания/имена, временный pin; нативные носители языка там, где оценивается качество.
- Чистая установка, offline после model setup, uninstall/reinstall, A→B, отмена update, launch с pending package, сохранность лицензии/модели/микрофона/shortcut и доказанное отсутствие persisted session glossary.
- 30 минут повторений: память должна выходить на плато после warm-up, retained audio — максимум одна актуальная запись, история — 10 текстов, без монотонного роста handles/buffers. Отдельно фиксировать cold/warm model load, first-result и stop-to-result latency, RAM peak; это ручной QA-отчёт без авто-upload.

**Public-release-ready:** устранены критические дефекты QA, проверены реальные upgrade/SmartScreen/standard-user сценарии, подписан выпуск, подтверждены hardware/model рекомендации и ограничения языковых сигналов, согласованы Windows commercial terms, privacy и download/update hosting. До этого не писать «verified Windows support» или «качество как на Mac».

## 8. Решения, которые можно отложить до раздачи/продаж

| Решение | Как продолжаем разработку без него | Когда понадобится |
| --- | --- | --- |
| Signing provider/certificate и доступ к CI secrets | Полный internal pipeline с test keys и unsigned internal installer, без подмены production trust | До подписанной внешней беты; проверить доступность провайдера для владельца |
| Место Windows release feed | Local test feed и CI artifacts; production URL не выдумывать и не прописывать несуществующим рабочим адресом | До внешней проверки реального update/download |
| Общая или отдельная лицензия Windows | LD1/существующий device contract, isolated beta authority, checkout disabled | До production activation/payments Windows |
| Реальный минимум RAM/CPU и модельная квантизация | Один закреплённый кандидат + измерительный harness + CPU fallback | После измерений тестировщиков, до публичных обещаний |
| Наличие Windows dictionaries и качество timing | Capability detection, обозначенные отключённые сигналы/segment replay, подготовленные языковые тесты | Во время физического QA, до verified-tier claims |

Не расширять этот перенос до Linux, web/cloud dictation, meeting recording, синхронизации словаря/истории, LLM-переписывания, аккаунтов, новых тарифов и Windows ARM64. Их отсутствие не препятствует parity с текущей Mac-версией.

## 9. Передача в следующий тред

Следующая реализация начинается с W9.0, затем идёт по W9.1–W9.6 без
перепрыгивания через проверяемые выходы. Старый
[WINDOWS_IMPLEMENTATION_PROMPT.md](WINDOWS_IMPLEMENTATION_PROMPT.md) остаётся
историческим заданием W0–W8 и не является актуальным prompt для догоняющего
обновления. Этот план сам по себе не публикует приложение, не включает
production endpoints и не заказывает тестирование.
