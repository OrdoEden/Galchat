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
    "defaultSelected": false
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
| `files` | 键是清单里的相对路径，值是文件全文；清单里的每个路径都必须有非空内容 |

限制：只含文字，不执行脚本、不访问链接；文件合计最多 1 MB，发送给模型的人格上下文最多 128 KB，超过会报错而不是截断。旧版导出的 `.json` 与单个 `.md` 仍可导入。

## 仓库里的人格

源文件放在 `Galchat/Personas/<id>/`，一个文件夹一个人格，统一结构：

```
<id>/
├── manifest.json          清单
├── PERSONA.md             核心：底色、放到聊天里怎么用、示例（发送给模型）
├── references/
│   ├── voice.md           说话的样子：语感、句库、分寸（发送给模型）
│   └── mindset.md         看事情的方式：心智模型、决策习惯（可选，发送给模型）
├── NOTICE.txt             来源、改写说明与免责声明（不发送）
└── LICENSE                上游是 MIT 等许可时保留原文（不发送）
```

生成可下载文件：

```sh
python3 scripts/build_personals.py   # 输出 dist/personals/<id>.personal
python3 scripts/check_personas.py    # 校验清单、体积、敏感词，以及 dist 是否最新
```

## 写人格时的约定

- 只写抽象后的性格与表达特点，不写来源作品、角色、真实人物、主播、平台或社群的名称，不引用影视台词。`check_personas.py` 内置一份转义保存的敏感词表，命中即失败。
- 回复里的“我”始终是用户本人，人格不得让模型冒充任何人，不得编造用户经历、伴侣、财富或行程。
- 不写脏话、辱骂家人、外貌/地域/性别攻击或威胁。
- 上游是 MIT 等宽松许可时，在 `licenseFiles` 保留许可原文与版权行；上游没有许可或是 AGPL 等传染性许可时，只参考公开的风格描述，全部文字原创，在 `NOTICE.txt` 说明。
