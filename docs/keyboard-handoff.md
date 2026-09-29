# 键盘对齐系统键盘：交接文档

日期：2026-09-28 · 分支：`fix/recognition-stickiness`

本轮把 Galchat 键盘从"带品牌行的建议面板"改成外观与交互对齐 iOS 系统中文键盘的输入法，
同时清掉项目里所有旧品牌名字样（代码、文案、文档、App Group 目录），并把键盘改为完全只读。**只做了静态编译，没有装机验证**；
真机检查项见文末和 `docs/keyboard-validation.md`。


> **2026-09-29 更新：键盘已拆成独立库 [`../SwiftKeyboard`](../../SwiftKeyboard/README.md)。**
> 键位、候选条、拼音行、⇧ 状态机、高度、拼音引擎和词库都在库里（`SwiftKeyboardViewController`、`PinyinInputEngine`）；
> `GalchatKeyboardExtension/KeyboardViewController.swift` 只继承它，负责读取 `ReplyBundle`/`AffectionProjection`、
> 通过 `suggestions()` 注入三条回复建议、在 `didSelectSuggestion(_:)` 里做会话确认与替换选中文字。
> 候选条几何仍来自 `GalchatShared/KeyboardTopMetrics.swift`，经 `configuration` 传给库。下文的文件位置以此为准。

## 1. 用户能看到的变化

| 方面 | 之前 | 现在 |
|---|---|---|
| 顶部 | 「旧品牌名 + 键盘 · 联系人」品牌行、好感度、确认会话、收起键盘、状态说明行 | 全部删除，只剩一行候选条 |
| 候选条 | 三个灰底方块按钮 + 单独一行拼音候选 | 一行常驻候选条：无拼音时三条回复建议等宽平铺，有拼音时横排拼音候选 |
| 候选样式 | 首项加粗、灰底；原文灰字 | 全部常规字重、统一文字色；只有首项白色托底；右侧 ⌄ 展开完整候选网格 |
| 拼音显示 | 在键盘里单独一行 | 输入框里带下划线的标记文本，按音节分隔（`ni hao`）；上屏改用单次 `insertText`，见 §4 |
| 按键排布 | 每排 `fillEqually` 拉伸，q 与 a 左对齐 | 字母键宽固定为整排 10 等分：第二排缩进半个键位，第三排 ⇧/⌫ 贴边、字母居中 |
| 功能键 | 分词、中/英、逗号 | 分词、中/英、逗号删除；新增 ⇧（单击大写一次，双击锁定） |
| 音节分隔符 `'` | 分词键 | 在 123 页（#+= 页也有），拼写中点它并入拼音并自动回字母页 |
| 回车 | 固定「换行」，有拼音时上屏原文 | 跟随 `returnKeyType`（发送/搜索/换行…），有拼音时显示「确认」并选第一候选 |
| 回复建议确认 | 先点「确认会话」按钮 | 首次点击某条建议即确认会话，再点一次才插入 |
| 键盘高度 | 写死 354pt，在布局回调里反复重设，弹出时逐帧长高 | 固定推导值，只在 `viewWillAppear` 和安全区变化时设定；候选条常驻，高度不随状态变化 |

## 2. 关键决策与原因

1. **不能往系统键盘注入候选。** iOS 没有让第三方往 Apple 键盘 QuickType 栏写内容的 API。
   IQKeyboardManager 只处理 App 内输入框的顶起，与此无关。自绘候选区是唯一做法（架构文档 §2 原本就这样写）。
2. **没有引入 KeyboardKit。** 许可证是闭源商业授权；以 `binaryTarget` 分发并依赖 LicenseKit 做许可校验，
   与键盘"不联网、不需要完全访问"的承诺冲突；官方也说明二进制只应链接到主 App。布局改为手写 `KeyRowView`。
3. **`'` 放在 123 页（方案 B）。** 系统键盘没有分词键；纯全拼引擎仍需 `'` 区分 `xi'an`/`xian`，
   所以放进符号页，不增加任何键或手势。代价是打「西安」要多切一次页。
4. **录屏解析器改用按键行定位键盘。** 原来靠键盘顶部的品牌文字当 OCR 锚点。
   现在认按键文字（整行 `qwertyuiop` 或逐键单字母，大小写都认，以及「空格/选定/换行/确认/发送/搜索/123/拼音/#+=」），
   至少 3 个命中才算；切线取首排按键顶边再往上 `KeyboardTopMetrics.reservedAboveKeys`（候选条 44 + 间距 8）
   按屏幕高度换算的比例，使候选文字也被排除。
5. **键盘不再写共享容器。** 原联系人确认行（写 `kb-contact-decision.json`）按 Apple 文档在未开完全访问时本就写不进去。
   已删除整条链路：`ContactDecision` 类型、`writeDecision/loadDecision/clearDecision`、
   `AffectionProjectionPublisher.consumeKeyboardDecision`、`LiveChatCoordinator.consumeContactDecision`。
   匿名会话的联系人绑定只由主 App 的 `resolveContact` 完成。
6. **App Group 子目录改为 `Galchat/`，不做旧目录回退。** 项目未发布，没有旧数据。

## 3. 代码位置

| 文件 | 内容 |
|---|---|
| `GalchatKeyboardExtension/KeyboardViewController.swift` | 键盘主体：候选条、拼音行、⇧ 状态机、布局、高度 |
| `GalchatKeyboardExtension/KeyboardLayoutViews.swift`（新） | `KeyRowView`（按键宽单位排版）、`CandidateGridView`（⌄ 展开网格） |
| `GalchatKeyboardExtension/PinyinInputEngine.swift` | 新增 `displaySpelling(for:)`：输入框显示用的音节切分 |
| `GalchatShared/KeyboardTopMetrics.swift`（新） | 候选条高度与间距，键盘与解析器共用 |
| `Galchat/Live/Capture/AppFrameExclusion.swift` | 按键行锚点与切线比例 |
| `GalchatShared/AffectionProjection.swift` | 删除 `ContactDecision` |
| `Galchat/Live/Affection/AffectionProjectionPublisher.swift` | 删除键盘确认的消费逻辑 |
| `GalchatShared/GalchatSharedFile.swift` | 子目录改为 `Galchat` |
| `Galchat/Live/Reply/ReplyBundlePublisher.swift` | 初始占位文案改为空（不再在候选条显示「…已启动，等待回复候选」） |

`LiveChatCoordinator.swift` 的对应改动（删 `consumeContactDecision`、传 `screenSize`）已随 `be327a2` 提交。

## 4. 实现要点

### 按键几何（按系统键盘截图实测，393pt 宽 iPhone）

| 项 | 值 |
|---|---|
| 两侧留白 / 键间距 | 4pt / 6pt |
| 字母键宽 | `(行宽 − 9 × 间距) / 10`，约 33pt |
| ⇧ / ⌫、123 / 🌐、换行 | 1.34 / 1.3 / 2.8 个字母键宽 |
| 键高 / 行距 | 42.5pt / 11.5pt（横屏 32 / 6） |
| 候选条高 / 与首排间距 | 44pt / 8pt |

按同一算法推算的键位与截图边界误差约 1pt。

### 拼音显示（2026-09-29 起改为键盘内显示）

最初拼音以标记文本（`setMarkedText`）显示在输入框里。真机录屏（App Store 搜索框）发现两个问题，已改回键盘内显示：

- **上屏错乱**：打 `keyboard` 选「可」后输入框只剩 `y bo a r d`，「可」丢失；再点原文 `yboard` 变成 `y bo a r dyboard`。
  宿主对 `setMarkedText → unmarkText → setMarkedText` 连续调用的处理与键盘侧状态不同步，且无从检测。
- **卡顿**：每次按键都改宿主的标记文本，宿主随之刷新搜索联想并回调 `textDidChange`/`selectionDidChange`，
  键盘每次回调都重建整排候选按钮；录屏里按键高亮和候选条比输入框晚约 1.1 秒。

09-29 当天先改成只在键盘内显示拼音，但与系统体验不一致，随后恢复为输入框标记文本，只换掉出问题的上屏方式：

- 拼写中 `setMarkedText(显示拼音)`；上屏（选词/原文）只调用一次 `insertText(结果)`，由宿主用结果替换标记文本，
  不再用 `setMarkedText(结果) → unmarkText()`。剩余拼音随后重新设为标记文本。
- `validateMarkedText()` 保留：同一输入框确认过「上下文包含标记文本」后，不匹配即作废组合。
- 若某宿主仍出错，库的 `Configuration.compositionStyle = .keyboardRow` 可改为只在键盘左上角显示拼音行。
- `renderCandidateBar()` 按内容签名去重，宿主回调频繁时不重复重建按钮；候选按钮改用轻量 `CandidateButton`。
- 词库在 `viewDidLoad` 时于后台线程预热（`PinyinInputEngine.prepare()`，引擎内部加锁）。
- 键帽阴影设置 `shadowPath`，避免逐键离屏渲染。
- `displaySpelling`：动态规划切分，完整音节代价 1、末尾半个音节 2、孤立字母 10。
  实测：`haha→ha ha`、`ttkaix→t t kai x`、`nver→nv er`、`zhon→zhon`、`xi'an→xi'an`。

### 高度

`applyHeight()` 只在 `viewWillAppear`、安全区变化、横竖屏切换时调用，约束优先级 `.required`，初值 216 占位。
不要把它放回 `viewWillLayoutSubviews` 无条件调用——那会让键盘弹出时逐帧改高度。
系统自身在键盘弹出时仍有一次尺寸跳变（Apple 论坛确认的已知问题，无官方绕过办法）。

## 5. 已知差距与风险

- **底排没有 😀 键**：键盘扩展调不出系统表情面板，空格因此比系统宽。
- **没有按键放大预览**（按住字母时上方弹出的大字）。
- **拼写中按 ⇧ 打字母**会先上屏覆盖整串拼音的候选（没有则上屏拼音原文），再插入大写字母；系统键盘是把大写字母并入标记文本。
- **解析器锚点**：键盘处于展开候选网格状态时按键不可见，解析器找不到锚点，这一帧键盘区域不会被切除。
- 回复建议仍需点两次（首次确认、再次插入）；换输入框或换联系人后确认失效。

## 6. 真机验证清单（优先）

1. 键盘弹出过程录屏抽帧：顶边只剩系统那一次跳变，不再逐帧长高。
2. 与系统键盘截图逐键比对：第二排缩进半键、第三排 ⇧/⌫ 贴边、底排宽度。
3. 微信、App Store 搜索框打 `nihao`：键盘拼音行显示 `ni hao`，输入框不变；选「你好」后输入框只多出「你好」。打 `keyboard` 选「可」再点原文：输入框为「可yboard」。
4. 打到一半点输入框别处，再按一个字母：不出现上一段拼音。
5. `xi` → 123 → `'` → `an`：拼音行 `xi'an`，候选含「西安」。
6. ⇧ 单击/双击、微信里回车显示「发送」。
7. 开录屏在聊天页打字：候选条文字和按键不进入聊天分析（`FrameRecorder` 的 sidecar 里 `keyboardTop` 应落在候选条之上）。

完整清单见 `docs/keyboard-validation.md`。
