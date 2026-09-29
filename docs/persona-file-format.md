# 人格文件格式（`.personal`）

用户只需要下载一个 `.personal` 文件，就能把人格导入 Galchat：

- 在“文件”、隔空投送、微信/浏览器下载里点开 `.personal`，选择用 Galchat 打开，App 会切到“人格”页并导入。
- 或者在“人格”页点 “+ → 从文件导入”，选中 `.personal` 文件。
- 标识相同的人格已存在时，会先确认再覆盖；导入不会自动切换当前人格。
- 在人格编辑页点“导出”，得到的也是 `<人格名>.personal`，可以直接分享。

## 文件内容

`.personal` 是一个 UTF-8 JSON 文件（统一类型标识 `com.heself.galchat.personal`，遵循 `public.json`，MIME `application/vnd.galchat.personal+json`）：

```json
{
  "assets": {
    "portrait.png": "<base64>"
  },
  "files": {
    "PERSONA.md": "# 名字\n\n这个人是什么样……",
    "references/voice.md": "# 说话的样子\n……",
    "NOTICE.txt": "来源与声明……"
  },
  "manifest": {
    "schemaVersion": 1,
    "id": "my-persona",
    "name": "名字",
    "summary": "一句话介绍",
    "version": "1.0.0",
    "documents": ["PERSONA.md", "references/voice.md"],
    "licenseFiles": ["NOTICE.txt"],
    "sourceURL": "https://example.com/可选",
    "sortOrder": 10,
    "defaultSelected": false,
    "portrait": "portrait.png"
  }
}
```

| 字段 | 说明 |
|------|------|
| `manifest.schemaVersion` | 固定为 `1` |
| `manifest.id` | 唯一标识，只允许 `A-Z a-z 0-9 - _ .`，最长 128 字节 |
| `manifest.name` / `summary` | 名称最多 50 字，简介最多 500 字 |
| `manifest.documents` | 按顺序完整发送给模型的 Markdown，第一份是“这个人是什么样” |
| `manifest.licenseFiles` | 随包保留、但不发送给模型的许可与署名 |
| `manifest.replyTransform` | 可选的回复后处理。目前只支持 `{"kind": "replaceText", "replacement": "恰"}`：候选排序后，把每个文字（汉字、字母、数字）换成 `replacement`（必须是一个字符），保留空格、标点和表情；改写后重复的候选补上不同的结尾标点。不认识的种类会导入失败，提示更新 App |
| `manifest.sendsPrompt` | 可选，默认 `true`。为 `false` 时选中这个人格不会发送任何说明给模型（回复建议与不使用人格相同），只做 `replyTransform` 这类后处理。文档仍需非空，可以只作展示 |
| `manifest.portrait` | 可选的形象图片路径，必须是 `assets` 里唯一的键。PNG 或 JPEG，最多 2 MB，建议 3:4 半身像、脸在上方（头像条取图片顶部的正方形）。没有时显示 App 标志 |
| `assets` | 二进制资源，值为 base64。目前只允许形象图片，不能有未声明的文件 |
| `files` | 键是清单里的相对路径，值是文件全文；清单里的每个路径都必须有非空内容 |

限制：不执行脚本、不访问链接；文字文件合计最多 1 MB，形象图片最多 2 MB，整个文件最多 4 MB，发送给模型的人格上下文最多 128 KB，超过会报错而不是截断。旧版导出的 `.json` 与单个 `.md` 仍可导入。

## 仓库里的人格

源文件放在 `Galchat/Personas/<id>/`，一个文件夹一个人格，统一结构：

```
<id>/
├── manifest.json          清单
├── PERSONA.md             核心：底色、放到聊天里怎么用、示例（发送给模型，必须是第一份）
├── references/
│   ├── voice.md           说话的样子：语感、句库、分寸（发送给模型）
│   └── <name>.md          其他补充说明，如 mindset.md（发送给模型）
├── portrait.png|jpg       形象（可选，需在清单写 "portrait"）
├── NOTICE.txt             来源、改写说明与免责声明（必需，不发送）
└── LICENSE                上游是 MIT 等许可时保留原文（不发送）
```

`check_personas.py` 会检查每个文件夹都符合这个结构：清单字段只能是已知字段，不允许多余文件。

生成可下载文件：

```sh
python3 scripts/build_personals.py   # 输出 dist/personals/：<id>.personal、portraits/、catalog.json
python3 scripts/check_personas.py    # 校验清单、体积、敏感词，以及 dist 是否最新
```

## 写人格时的约定

- 只写抽象后的性格与表达特点，不写来源作品、角色、真实人物、主播、平台或社群的名称，不引用影视台词。`check_personas.py` 内置一份转义保存的敏感词表，命中即失败。
- 回复里的“我”始终是用户本人，人格不得让模型冒充任何人，不得编造用户经历、伴侣、财富或行程。
- 不写脏话、辱骂家人、外貌/地域/性别攻击或威胁。
- 上游是 MIT 等宽松许可时，在 `licenseFiles` 保留许可原文与版权行；上游没有许可或是 AGPL 等传染性许可时，只参考公开的风格描述，全部文字原创，在 `NOTICE.txt` 说明。

## 远程资源库（人格 + Jev 题目）与下架

App 内置的资源库地址在 `ResourceCatalog.sourceURLs`：先读 `https://raw.githubusercontent.com/OrdoEden/GalchatResource/main/catalog.json`，失败时再读 jsDelivr 镜像。发布时把 `dist/personals/` 的全部内容推到这个仓库的根目录。

`catalog.json`：

```json
{
  "schemaVersion": 1,
  "personas": [
    {"id": "…", "name": "…", "summary": "…", "version": "1.0.0",
     "package": "<id>.personal", "sha256": "…", "size": 5530,
     "portrait": "portraits/<id>.png", "sortOrder": 0}
  ],
  "revoked": [{"id": "…", "reason": "…"}],
  "prompts": {"version": "1.0.0", "package": "prompts/prompts.json", "sha256": "…", "size": 10842}
}
```

- `package`、`portrait` 可以写相对路径（按 catalog.json 所在目录解析），只接受 HTTPS。App 下载后校验大小和 SHA-256，再按上面的规则校验人格包，包里的标识和版本必须与目录一致。
- App 在人格页出现、回到前台时同步（最多每 30 分钟一次），人格库页面每次打开都会刷新，也可以下拉刷新。
- 自动更新：本机来源是“随 App 附带”或“从人格库下载”、且没在本机编辑过的人格，目录版本更高时静默更新。编辑、新建、从文件导入的人格记为本机人格，不自动覆盖；在人格库里手动更新前会先确认。
- 下架：把 `{"id": "…", "reason": "…"}` 加进 `catalog/revoked.json` 后重新生成并发布。下架的人格不再出现在目录里；App 同步后会删除本机同标识的人格（包括改过的），如果正在使用就改为不使用，提示用户，之后也拒绝再次导入。从名单里移除后可以重新下载，但不会自动装回。
- 用户可以在人格页长按形象卡删除任何人格，包括附带的人格。

## 提示词包（`prompts.json`）

`Galchat/Prompts/prompts.json` 收录 App 发给模型的全部提示词：`reply`（回复生成的系统提示词）、`sticker`（表情包解读）、以及 Jev 部分。解析代码在 App 里：`reply` 要求的输出格式必须和 `ReplyClient.parseThree` 能解析的一致（JSON 数组、3 条）。连通性测试那句留在代码里。

Jev 部分：判断接口的题目说明、各选项的判定标准、`danger_level` 的 10 档评分标准和候选排序题的说明，同样随 App 附带，也随资源库发布到 `prompts/prompts.json`。

```json
{
  "schemaVersion": 1,
  "version": "1.0.0",
  "backgroundNote": " Facts given in background are provided context, not off-topic.",
  "reply": "你是中文即时通讯回复助手。……",
  "sticker": "你是聊天表情包解读助手。……",
  "judge": {
    "literal_question": {"type": "noul", "instructions": "…", "criteria": {"true": "…", "false": "…"}},
    "danger_level": {"type": "score", "instructions": "…", "criteria": ["第 0 档", "…", "第 9 档"]},
    "true_intent": {"type": "choice", "instructions": "…", "criteria": {"confirm_you_care": "…", "…": "…"}}
  },
  "rank": {"best_reply": {"type": "choice", "instructions": "…"}}
}
```

- 发送时每道题的 `instructions` 末尾会接上 `backgroundNote`；`best_reply` 的选项是运行时的三条候选，不写在文件里。
- **只能改措辞**。题目 id、题型、选项 key、`danger_level` 的档位数是代码约定（`JudgeClient` 按 key 取答案，`AffectionScoring` 按 `affection_delta` 的选项计分，PiP 按选项 key 显示中文，第 9 档表示破裂），App 端 `PromptPack.judgeContract` 和 `check_personas.py` 的 `JEV_JUDGE` 按同一约定校验，不符合的题目包整体拒绝。要增删题目或选项，需要同时改代码并发布新版 App，再把 `schemaVersion` 或约定一起升级。
- 更新措辞：改文件、调高 `version`，运行 `build_personals.py` 后发布。App 同步到更高版本时下载、校验大小和 SHA-256、按约定校验，通过后保存到 `Application Support/ResourceLibrary/`，下一次判断起生效；失败则保留当前版本。App 自带的版本更新时以版本号高的为准。
- 措辞改动会直接影响判断结果，发布前建议用校准对话集回归一遍。
