# 好感度动图：动心 / 心碎

PiP 好感度旁的爱心按本次好感度变化方向切换动图（`GCPiPView.heartAnimations`）：

| 变化 | 资源 | 帧数 / 循环时长 | 内容 |
| --- | --- | --- | --- |
| 持平 | `heartbeat.gif` | 14 / 1.68 s | 原有心跳 |
| 上升 | `heartflutter.gif` | 9 / 1.54 s | 蓄力压扁 → 弹起放大 → 迸出小爱心与闪光 → 二次轻跳 → 小爱心上飘消失 → 停顿 |
| 下降 | `heartbreak.gif` | 11 / 2.18 s | 静止 → 左右颤抖出现裂纹 → 裂纹贯穿 → 碎成两半迸出碎屑 → 两半外倾下坠、褪成灰粉 → 停顿 |

三个 GIF 均为 96×96、透明背景、无限循环，首帧都是与心跳相同位置（bbox 20,24–76,73）的完整爱心，因此暂停、减弱动态效果或关系破裂时停在首帧不会跳位。Visyn 按视频时钟取模循环，所以两个新动图末尾带较长停顿，而不是单次播放。

## 生成流程

1. 以 `heartbeat.gif` 首帧放大到 512px、贴绿幕作为参考图。
2. 用 gen-image（`gpt-image-2-1k`，同步，`--reference-image`）分别生成 3×3 绿幕关键帧图。
3. `python3 scripts/build_heart_gifs.py sheet_flutter.png sheet_broken.png Galchat/Resources` 切格、抠绿（仅保留粉/玫红/白色像素，顺带去掉光晕）、按主爱心对齐缩放到 56px 宽、把外围粒子按椭圆径向收拢进 96px 画布、4× 超采样后输出 1-bit 透明 GIF，并附预览条。

## Prompt

公共部分（两条 prompt 末尾都附上）：

```
STYLE (must match exactly in every cell): a flat 2D kawaii emoji-style heart icon, solid pink fill #F26289, one small round pale-pink highlight dot #FFB4C5 near the upper-left lobe, a very thin slightly darker rose outline, no gradients, no shading, no texture, no text, no faces. Simple clean vector look, readable when shrunk to 96 pixels.
LAYOUT: a 3x3 sprite sheet of 9 animation keyframes on a perfectly flat pure chroma-green background #00FF00, no grid lines, no borders, no numbers. Read left-to-right, top-to-bottom. Every cell is the same size, the heart is centered in its cell at the same base size (about 55% of the cell width), same camera, same scale, nothing touches cell edges, nothing crosses into neighbour cells. No shadows on the background.
```

动心（好感度上升）：

```
ANIMATION "flutter / falling in love" (affection increasing), 9 keyframes:
1. the intact pink heart, calm.
2. the heart squashes down slightly (anticipation), a little wider and shorter.
3. the heart springs up and grows about 15% bigger, stretched slightly taller.
4. the heart at its biggest, three tiny pink mini-hearts and two small four-point white sparkles pop out around it.
5. the heart settles back towards normal size, the mini-hearts float up and outward, sparkles twinkle.
6. the heart does a small second pulse (slightly bigger than normal), mini-hearts rise higher and shrink.
7. heart normal size, soft pale pink blush glow ring around it, mini-hearts near the top of the cell, smaller.
8. heart normal size, mini-hearts tiny and fading at the top, one small sparkle left.
9. the intact pink heart, calm, identical to frame 1.
Mini-hearts use the same pink #F26289 and same flat style, much smaller than the main heart.
```

心碎（好感度下降）：

```
ANIMATION "heartbreak" (affection decreasing), 9 keyframes:
1. the intact pink heart, calm.
2. the heart squeezes slightly (a small shiver), a tiny short zig-zag crack appears at the top notch.
3. a thin white-edged zig-zag crack runs from the top notch halfway down the heart.
4. the zig-zag crack runs all the way through the heart, top notch to bottom tip, heart still together.
5. the heart splits along the jagged zig-zag into a left half and a right half, a small gap between them, two or three tiny pink shards pop out of the gap.
6. the two halves drift apart and tilt outward (left half rotates counter-clockwise, right half clockwise), shards falling.
7. the halves are further apart, tilted more and sagging lower, colour slightly desaturated dusty pink.
8. the halves hang low and droop, dusty muted pink #D98AA0, shards gone.
9. the two broken halves resting low and apart, muted dusty pink, still, same jagged edges.
The zig-zag split line must be identical in shape in every frame from 4 to 9, the halves are exactly the two pieces of the original heart.
```
