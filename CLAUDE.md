# Many2Mono - Maven Monorepo Migration Tool

## Цель проекта

Инструмент для объединения нескольких Maven репозиториев в одну монорепу с сохранением git-истории и автоматической генерацией BOM (Bill of Materials).

## Структура проекта

```
Many2Mono/
├── Makefile        # Основной скрипт сборки
├── repos.txt       # Список репозиториев для миграции
├── templates/      # Шаблоны для генерации файлов
│   ├── aggregator-pom.xml         # Шаблон корневого pom.xml
│   ├── parent-pom.xml             # Шаблон parent pom.xml
│   ├── module-bom-pom.xml         # Шаблон BOM модуля
│   ├── root-bom-internal-pom.xml  # Шаблон корневого BOM
│   ├── gitignore                  # Шаблон .gitignore
│   ├── .github/                   # GitHub конфигурация
│   │   ├── CODEOWNERS             # Владельцы кода
│   │   ├── auto-labeler-config.yaml
│   │   ├── release-drafter-config.yml
│   │   └── workflows/             # GitHub Actions workflows
│   └── licence/                   # Лицензионные файлы
│       ├── CODE-OF-CONDUCT.md     # Код поведения для монорепы
│       ├── CONTRIBUTING.md        # Руководство для контрибьюторов
│       ├── LICENSE                # Лицензия проекта
│       └── SECURITY.md            # Политика безопасности
├── tmp/            # (создаётся) Временные bare-репозитории
├── monorepo/       # (создаётся) Готовая монорепа
│   ├── pom.xml     # (генерируется) Корневой aggregator pom.xml
│   ├── CODE-OF-CONDUCT.md          # (копируется) Код поведения
│   ├── CONTRIBUTING.md             # (копируется) Руководство контрибьюторов
│   ├── LICENSE                     # (копируется) Лицензия
│   ├── SECURITY.md                 # (копируется) Политика безопасности
│   ├── .gitignore                  # (копируется) Файл gitignore
│   ├── .github/                    # (копируется) GitHub конфигурация и workflows
│   ├── parent/                     # (генерируется) Parent pom
│   │   └── pom.xml                 # Общий parent для всех модулей
│   ├── bom-internal/               # (генерируется) Корневой BOM
│   │   └── pom.xml                 # Импортирует все BOM-ы модулей
│   └── <subdir>/   # Субдиректории с кодом из каждого репо
│       ├── pom.xml # (с ссылкой на parent)
│       ├── module-1/
│       └── <subdir>-bom-all/        # (генерируется) BOM для этого модуля
│           └── pom.xml             # BOM с dependencyManagement
└── CLAUDE.md       # Этот файл
```

## Формат repos.txt

Одна строка = один репозиторий:
```
URL|субдиректория
```

Пример:
```
https://github.com/Netcracker/qubership-core-utils|core-utils
# закомментированные строки игнорируются
```

## Команды Make

| Команда | Описание |
|---------|----------|
| `make all` | Полный цикл: clone + merge + aggregator + parent + bom + add-licence |
| `make clone` | Клонирование репозиториев в tmp/ |
| `make merge` | Создание монорепы из уже склонированных репозиториев |
| `make init` | Alias для clone + merge (обратная совместимость) |
| `make aggregator` | Генерация корневого aggregator pom.xml |
| `make parent` | Генерация parent pom.xml и добавление ссылок в модули |
| `make bom` | Генерация всех BOM (module-bom + root-bom) |
| `make module-bom` | Генерация BOM в каждом модуле монорепы |
| `make root-bom` | Генерация корневого bom-internal (импортирует все BOM-ы модулей) |
| `make add-licence` | Копирование LICENSE, CONTRIBUTING.md и др. в корень, удаление из модулей |
| `make add-workflows` | Копирование .github/ из templates в корень монорепы |
| `make bom-clean` | Удаление сгенерированных BOM и их ссылок из pom.xml |
| `make clean` | Удаление всех сгенерированных BOM (вызывает bom-clean) |
| `make clean-aggregator` | Удаление корневого pom.xml |
| `make clean-parent` | Удаление parent pom.xml |
| `make clean-root-bom` | Удаление корневого bom-internal |
| `make clean-all` | Удаление tmp/ и monorepo/ |

## Требования

- **bash** (запускать в WSL или Linux)
- **git**
- **git-filter-repo** (`pip install git-filter-repo`)
- **xmlstarlet** (`apt install xmlstarlet`)

## Важно для WSL

Перед запуском конвертировать файлы в Unix-формат:
```bash
dos2unix Makefile repos.txt
```

## Настройка корневого Aggregator (опционально)

Вы можете настроить координаты корневого pom.xml через переменные окружения:

```bash
export MONOREPO_GROUP_ID="com.mycompany.platform"
export MONOREPO_ARTIFACT_ID="platform-parent"
export MONOREPO_VERSION="2.0.0-SNAPSHOT"
make aggregator
```

Или указать их прямо в команде:
```bash
MONOREPO_GROUP_ID="com.mycompany.platform" make all
```

## Как работает

### Шаг 1: clone
1. Клонирует каждый репозиторий как bare в `tmp/`
2. Применяет `git filter-repo --to-subdirectory-filter` для переноса файлов в субдиректорию

### Шаг 2: merge
1. Создаёт пустую монорепу в `monorepo/`
2. Мёржит все уже склонированные репозитории из `tmp/` с `--allow-unrelated-histories`

### Шаг 3: aggregator
1. Читает шаблон из `templates/aggregator-pom.xml`
2. Заменяет плейсхолдеры (`@MONOREPO_GROUP_ID@`, `@MONOREPO_ARTIFACT_ID@`, `@MONOREPO_VERSION@`)
3. Генерирует секцию `<modules>` из `repos.txt` в порядке объявления
4. Создаёт корневой `pom.xml` в `monorepo/`
5. Использует параметры из переменных Makefile (можно переопределить):
   - `MONOREPO_GROUP_ID` (по умолчанию: com.netcracker.cloud)
   - `MONOREPO_ARTIFACT_ID` (по умолчанию: qubership-core-java-libs)
   - `MONOREPO_VERSION` (по умолчанию: 1.0.0-SNAPSHOT)

### Шаг 4: parent
1. Читает шаблон из `templates/parent-pom.xml`
2. Создаёт `monorepo/parent/pom.xml` с:
   - `groupId`: `MONOREPO_GROUP_ID`
   - `artifactId`: `MONOREPO_ARTIFACT_ID-parent`
   - `version`: `MONOREPO_VERSION`
   - Импортирует корневой BOM (`MONOREPO_ARTIFACT_ID-bom-internal`)
   - Содержит общие properties (compiler version, encoding)
   - Содержит license информацию
3. Добавляет `parent` в корневой aggregator pom.xml (первым модулем)
4. В каждом модуле первого уровня добавляет секцию `<parent>`:
   ```xml
   <parent>
       <groupId>com.netcracker.cloud</groupId>
       <artifactId>qubership-core-java-libs-parent</artifactId>
       <version>1.0.0-SNAPSHOT</version>
       <relativePath>../parent</relativePath>
   </parent>
   ```

### Шаг 5: bom (module-bom + root-bom)

#### 5.1: module-bom
1. Для каждого модуля первого уровня:
   - Проверяет наличие BOM директории (если есть - пропускает)
   - Извлекает groupId и version из корневого pom.xml модуля
   - Сканирует все pom.xml внутри модуля и собирает координаты артефактов
2. Создаёт `<module>-bom/pom.xml` используя шаблон `templates/module-bom-pom.xml`:
   - `<parent>` - ссылается на корневой pom.xml модуля
   - `<artifactId>` - `<module>-bom`
   - `<dependencyManagement>` - все артефакты модуля
   - Все версии установлены в `${project.version}`
3. Добавляет `<module>-bom` в секцию `<modules>` корневого pom.xml модуля

#### 5.2: root-bom
1. Читает шаблон из `templates/root-bom-internal-pom.xml`
2. Сканирует все модули первого уровня и для каждого:
   - Если модуль уже имел свой BOM - добавляет комментарий
   - Если BOM был сгенерирован - добавляет `<dependency>` с `scope=import`
3. Создаёт `monorepo/bom-internal/pom.xml` - корневой BOM, импортирующий все BOM-ы модулей
4. Добавляет `bom-internal` в корневой aggregator pom.xml

### Шаг 6: add-licence
1. Копирует файлы из `templates/licence/` в корень монорепы:
   - `CODE-OF-CONDUCT.md`
   - `CONTRIBUTING.md`
   - `LICENSE`
   - `SECURITY.md`
2. Удаляет эти же файлы из всех модулей первого уровня (чтобы избежать дублирования)

### Шаг 7: add-workflows
1. Копирует директорию `templates/.github/` в корень монорепы
2. Если `.github/` уже существует - удаляет и заменяет на шаблон
3. Включает GitHub Actions workflows, CODEOWNERS и другие файлы конфигурации

## Особенности генерации Aggregator

- Использует шаблон из `templates/aggregator-pom.xml`
- Корневой `pom.xml` создается только если его еще нет
- Модули добавляются в том же порядке, что и в `repos.txt`
- Плейсхолдеры в шаблоне: `@MONOREPO_GROUP_ID@`, `@MONOREPO_ARTIFACT_ID@`, `@MONOREPO_VERSION@`, `@MODULES@`
- XML экранируется автоматически через функцию `xml_escape`

## Особенности генерации Parent

- Использует шаблон из `templates/parent-pom.xml`
- Создаётся в `monorepo/parent/pom.xml`
- ArtifactId: `MONOREPO_ARTIFACT_ID-parent`
- Импортирует корневой BOM для централизованного управления зависимостями
- Содержит общие properties для всех модулей (Java version, encoding)
- Автоматически добавляется в корневой aggregator как первый модуль
- Все модули первого уровня получают ссылку на parent через `<parent>` секцию
- Пропускает специальные директории (`.git`, `parent`, `bom-internal`)
- Если модуль уже имеет parent - не перезаписывает

## Особенности генерации BOM

**BOM для модулей:**
- Использует шаблон из `templates/module-bom-pom.xml`
- BOM генерируется отдельно для каждого модуля первого уровня
- Упрощенная структура: `<module-name>/<module-name>-bom-all/pom.xml` (один файл)
- ArtifactId: `<module-name>-bom-all`
- Parent: ссылается на корневой pom.xml модуля (`<module-name>`)
- Если в модуле уже есть BOM (директория оканчивающаяся на "-bom" или с именем "bom"), BOM не генерируется
- Все версии в BOM ссылаются на `${project.version}` родительского модуля
- BOM автоматически добавляется в секцию `<modules>` корневого pom.xml модуля
- При редактировании существующих pom.xml сохраняется оригинальное форматирование и пустые строки

**Корневой BOM:**
- Использует шаблон из `templates/root-bom-internal-pom.xml`
- Создаётся в `monorepo/bom-internal/pom.xml`
- Версии ВСЕХ модулей выносятся в секцию `<properties>` с именами `<module-name.version>`
- Импортирует BOM-ы через `<scope>import</scope>`, используя properties для версий:
  - **Сгенерированные BOM** - всегда импортируются
  - **Существующие BOM** - импортируются если:
    - В модуле найдена ровно одна BOM директория (оканчивается на "-bom" или имеет имя "bom")
    - В найденной BOM директории нет поддиректорий (файлы типа README допустимы)
    - BOM pom.xml содержит валидные координаты (groupId, artifactId)
  - **Пропускаются** (добавляется только комментарий) если:
    - В модуле несколько BOM директорий
    - BOM директория содержит поддиректории
    - Координаты BOM не найдены или pom.xml отсутствует
- Автоматически добавляется в корневой aggregator pom.xml
- Позволяет централизованно управлять всеми зависимостями монорепы
- Пример property: `<core-utils.version>1.0.0-SNAPSHOT</core-utils.version>`

## TODO / Возможные улучшения

- [x] Генерация GitHub workflows (.github/workflows/) - реализовано через `make add-workflows`
- [x] Генерация .gitignore для монорепы - реализовано через `make add-gitignore`
- [ ] Параллельное клонирование репозиториев
- [ ] Опциональное удаление tmp/ после успешного clone
