# WinModernSC

[English](README.md)

## 这个项目是干什么的

WinModernSC 把 Windows 的界面字体整机换掉 —— 外壳、老式 Win32 对话框、UWP/WinUI 程序、
浏览器网页、Office 文档，全都换成你自己指定的一套字体。

分两步走。三个 Python 脚本读 `source\` 里的字体，生成三组文件：12 个文件的 `Segoe UI`
家族（静态，只管拉丁）、1 个 Windows 11 外壳在用的可变字体 `Segoe UI Variable`，以及
8 个顶替 Windows 中文族（微软雅黑 / 宋体 / 黑体 / 等线）的文件，一共 21 个。然后一个
PowerShell 脚本把这些文件接到四套注册表机制上，动手之前先把每一个会被改的值备份下来。

**推荐用 [SarasaGothicSC-TTF](https://github.com/be5invis/Sarasa-Gothic/releases)** ——
TTF 发布包，不要 `-Unhinted` 那版。这一套是本项目实测验证过、效果最好的组合：更纱黑体
自带完整的 TrueType 指令，Windows 界面文字那种小像素尺寸下笔画仍然分得开；而且它拉丁和
汉字在同一套字体里，两半天生协调。

任何简体中文字体都能用，只要 `source\` 里的文件符合 `<Family>-<Style>.ttf` 命名规则、
摆法是[三种合法摆法](#1-把源字体放进-source)之一。源可以是一组静态字重、一个可变字体，
或者两者并存。必需的只有正体 —— 简中字体大多压根不带斜体，缺了的话由脚本拿对应的正体
剪切出来。

## 四套机制

每一套管一层，别的机制都够不着那一层。`main.ps1` 负责解析参数、校验管理员、管着备份文件
和公共 helper，具体活分给 `src\` 下面一个机制一个文件。

| # | 干什么 | 定义在哪 |
| --- | --- | --- |
| **1** | 把 `Fonts` 注册表键指向生成出来的那 21 个文件（12 个静态 `Segoe UI`、1 个 `Segoe UI Variable`、8 个中文族），GDI 和 DirectWrite 都是从字体文件里读族名的，所以外壳、UWP/WinUI、浏览器、Office 全跟着变。 | [`src/main_fonts.ps1`](src/main_fonts.ps1) |
| **2** | 写 `FontSubstitutes`，把 `Tahoma`、`MS Shell Dlg`、`MS Sans Serif` 这些老族名指向 `Segoe UI`，兜底那些还在请求它们的老式 Win32 程序。 | [`src/main_font_substitutes.ps1`](src/main_font_substitutes.ps1) |
| **3** | 写 `WindowMetrics` 里那 6 个 LOGFONT（标题栏、调色板标题、菜单、对话框、状态栏、图标文字），外加标题栏高度和窗口边框 —— 这是唯一能改字号的一层。 | [`src/main_window_metrics.ps1`](src/main_window_metrics.ps1) |
| **4** | 往每个 `Segoe UI` 族的 `FontLink\SystemLink` 最前面插两条，让 GDI 的中文回退走机制 1 装的那批文件，而不是 `%windir%\Fonts` 里的原版。按字重挂对应那一档，原来的链原样接在后面。 | [`src/main_font_link.ps1`](src/main_font_link.ps1) |

四套的还原统一由 [`src/main_revert.ps1`](src/main_revert.ps1) 负责，依据是各机制动手之前
写下的那份备份 JSON。

### 机制之间的依赖关系

**机制 1 是地基，2、3、4 都建立在它之上。** 但缺了它没有任何一套会报错 —— 该写什么照写
不误 —— 变的是*结果*：

- **2 和 3** 只是把字体请求引向 `Segoe UI` 这个族名。这个族名到底解析成你的字体还是微软
  原版，完全取决于机制 1 有没有装过（这次装或者之前装过都算）。`-no-fonts` 和这两个之一
  一起用时，`main.ps1` 会打一条警告。
- **4 对 1 的依赖有两层。** 它要读 `Fonts` 键里【对应字重那一档】微软雅黑当前指向的文件
  来拼回退链的第一行，所以必须排在机制 1 【之后】执行 —— `main.ps1` 保证了这个顺序。
  而且它要解决的问题（`Segoe UI` 那批文件的汉字被裁掉了）本来就是机制 1 造成的；没有 1，
  `Fonts` 键里还是裸文件名 `msyh.ttc`，机制 4 会整条跳过，一个值都不写。
- **2、3、4 相互之间没有依赖**，可以任意组合跳过。

## 亮点

下面每一条都指明是哪套机制、哪个文件做的。

**1. 两条渲染路径都覆盖。** 机制 1（[`src/main_fonts.ps1`](src/main_fonts.ps1)）指过去的
文件自己带着目标族名，GDI 和 DirectWrite 都从文件里读族名，两边一起变。机制 2
（[`src/main_font_substitutes.ps1`](src/main_font_substitutes.ps1)）再兜底只认
`FontSubstitutes` 的老式 Win32 程序，机制 4
（[`src/main_font_link.ps1`](src/main_font_link.ps1)）让 GDI 的中文回退也走同一批文件。
手工改 `FontSubstitutes` 只覆盖得到 GDI 那一半。

**2. 网页和文档里按名字点名要的中文也能接管。**
[`src/make_cjk.py`](src/make_cjk.py) 在产物里同时写英文族名和本地化族名
（`Microsoft YaHei` / 微软雅黑、`SimSun` / 宋体、`SimHei` / 黑体、`DengXian` / 等线），
机制 1 再把对应的 `Fonts` 注册项指过去。于是网页里 `font-family: 微软雅黑`、Word 正文
指定的宋体，解析出来都是新字体。这件事 `FontSubstitutes` 做不到，DirectWrite 无视那张表。

**3. 拉丁和汉字来自同一套源字体。** [`src/make_segoe_ui.py`](src/make_segoe_ui.py) 把生成的
`Segoe UI` 家族裁到和真 Segoe UI 一样的覆盖范围，汉字剥掉 —— 真 Segoe UI 本来也一个汉字
都没有。掉出去的汉字由机制 4 引到 `make_cjk.py` 用同一套源字体造出来的中文文件上。

**4. 源字体缺的字会补上，而且尽量拼、不搬。**
[`src/patch_glyphs.py`](src/patch_glyphs.py) 把「被顶替的那个 Windows 字体有、源字体没有」
的重音字母和符号补进产物。能分解的字符（`À = A + ̀ `）拼成复合字形，base 直接引用源字体
自己的字母，字宽和风格都不变；分解不出来的才整个搬。详见「[生成字体](#2-生成字体)」。

**5. Windows 11 外壳那一层也换得掉。** Win11 的设置、开始菜单，以及所有 WinUI 3 程序，用的
不是那 12 个静态文件，而是可变字体 `Segoe UI Variable` —— 它在 `Fonts` 键里是独立的一项。
[`src/make_vf.py`](src/make_vf.py) 专门造这一个，`name` / `fvar` / `STAT` 全部照抄系统里
真的 `SegUIVar.ttf`，微软以后换版本调了分档，产物跟着变。

**6. 改的是字号和窗口几何，不只是族名。** 机制 3
（[`src/main_window_metrics.ps1`](src/main_window_metrics.ps1)）写那 6 个 LOGFONT 外加
标题栏高度和边框宽度，本机每个用户配置单元都写一遍，`HKU\.DEFAULT` 和新用户模板也算在内，
所以新建的账户和登录前的界面一样管。备份里记着当时的 `AppliedDPI`，还原时显示缩放变过就
按比例把 `lfHeight` 换算回去。noMeiryoUI 只做这一层，够不着浏览器、UWP 和 Office。

**7. 全量备份、一键回退、DryRun 预演。** 每一个将要被写的值，动手之前都先存进
`winmodernsc-backup.json`，原本不存在的记成 null，还原时删掉。安装那趟建出来的注册表键
如果最后空了也会删，所以 `-revert` 不留残渣。`-DryRun` 把四套机制要做的改动完整打印出来，
一个字节都不写。

**8. 不注入进程，不替换系统文件。** 字体文件复制到 `C:\Fonts`，注册表指过去就完事，
`%windir%\Fonts` 底下一个文件都不动、不删。装完之后没有任何东西在后台跑 —— 作为对比，
MacType 是注入进程、在运行时改渲染。

**9. 不锁定输入字体。** [`src/util.py`](src/util.py) 扫 `source\`，判定出源类型
（`STATIC` / `VF` / `BOTH`）之后三个生成脚本各自分支。静态那条路只要求 Regular / Light
外加 Bold 或 Black 之一，多出来的字重有就用；可变那条路每个输出该切哪一档，直接读它冒充的
那个 Windows 字体的 `usWeightClass`。斜体不是必需的，缺了就拿对应的正体剪切出来。

## 环境要求和配置步骤

### 环境要求

- **Windows 10 或 11**，`%windir%\Fonts` 里要有简体中文字体、静态的 Segoe UI 文件，
  以及可变的 `SegUIVar.ttf`：`msyh.ttc`、`msyhbd.ttc`、`msyhl.ttc`、`simsun.ttc`、
  `simhei.ttf`、`Deng.ttf`、`Dengb.ttf`、`Dengl.ttf`，`segoeui.ttf` … `seguibli.ttf`，
  外加 `SegUIVar.ttf`。
- **Python 3.8+**，装 fontTools：`pip install fonttools`
- **管理员权限的 PowerShell** —— Windows PowerShell 5.1 和 PowerShell 7 都行。
  只有 `-DryRun` 不需要提权。
- **`C:` 盘约 205 MB 空间**放生成的字体（大头是中文那 8 个文件）。源是可变字体时
  `SegoeUI-Variable.ttf` 会把整个源搬过来，按源字体大小再多几十 MB。

### 1. 把源字体放进 `source\`

把任意一套简体中文字体解压/复制到 `WinModernSC\source\` 即可，只要文件符合下面的命名
规则就行。推荐（也是实测效果最好的）是 [Sarasa Gothic 的 releases 页](https://github.com/be5invis/Sarasa-Gothic/releases)
里的 SarasaGothicSC TTF 包 —— 如果用它，选 TTF 发布包，不要 `-Unhinted` 那版。

这个目录的命名规则：

- 每个文件必须叫 `<Family>-<Style>.ttf`，例如 `SarasaGothicSC-Regular.ttf`、
  `SarasaGothicSC-BoldItalic.ttf`。
- 同一目录里 `<Family>` 必须完全一致 —— 一个目录只放一套字体，混了直接判非法，
  不去猜哪一套是主的。
- `VF` 是保留的样式名，专指可变字体：`<Family>-VF.ttf`，一个目录最多一个。名字和内容
  必须对得上 —— 叫 `-VF.ttf` 却没有 `fvar` 表、或者带 `fvar` 表却用了静态字重的样式名，
  都会当场报错。（后者尤其要拦：那会让 `fvar` / `STAT` 跟着装进 `Segoe UI` 那一族，
  DirectWrite 于是拿 STAT 去推家族名，整族的字重档位全乱。）

**三种合法摆法，别的都判非法。** 校验结果会明确打出源类型，后面三个生成脚本都按它分支：

| 源类型 | `source\` 里放什么 | 三个脚本怎么走 |
| --- | --- | --- |
| `STATIC` | 一组静态字重：至少 `Regular` + `Light`，外加 `Bold` 或 `Black` 之一 | 12 个 `Segoe UI` 和 8 个中文族各挑一个静态字重；`Segoe UI Variable` 由静态字重合成 |
| `VF` | 单独一个 `<Family>-VF.ttf` | 三组产物全部从这个可变字体实例化出来；`Segoe UI Variable` 直接改造它，不合成 |
| `BOTH` | `<Family>-VF.ttf` 加上满足 `STATIC` 那一条的静态文件 | 12 个 `Segoe UI` 和 8 个中文族仍走静态那条路（静态字重是作者调过的，比插值出来的准）；`Segoe UI Variable` 用现成的 VF |

- `STATIC` 和 `BOTH` 缺任何一个必需字重都会直接报错退出，并明确列出缺的是哪几个文件。
- 斜体样式可有可无。给了就原样用；不给的话，6 个斜体输出由对应的正体剪切生成。源是可变
  字体时，带 `ital` 或 `slnt` 轴就切真斜体，不带才剪切。
- 额外的样式（`ExtraLight`、`SemiBold`、`SemiLight` …）有就用，没有就跳过。

想让 Win11 外壳真正拿到多档字重，就给 `source\` 加一个 `<Family>-VF.ttf`（`BOTH` 摆法）：
`STATIC` 源合成出来的 `Segoe UI Variable` 多半没有 `wght` 轴，各档字重靠 Windows 自己的
合成加粗。那 12 个静态 `Segoe UI` 文件不受影响，它们本来就是各用各的静态字重。

### 2. 生成字体

```bash
python src\make_vf.py
```

```bash
python src\make_segoe_ui.py
```

```bash
python src\make_cjk.py
```

第一个往 `SegoeUIMod\` 写 `SegoeUI-Variable.ttf`（源是静态字重时约 0.4 MB，源是可变字体
时整个搬过来，几十 MB），第二个往同一个目录写 12 个静态文件（约 4 MB），第三个往
`CJKMod\` 写 8 个文件（约 200 MB）。三个脚本开跑前都会先打一张表，说明每个输出是用哪个
源字重造的；`make_vf.py` 还会把源类型、合成还是直接改造、以及兼容率都打出来。

三个脚本之间没有先后要求，各写各的目录（`make_vf.py` 和 `make_segoe_ui.py` 共用
`SegoeUIMod\`，但文件名不重叠，两边的自检都知道对方的产物不是残留旧文件）。

**缺的字会自动补上。** 被顶替的那个 Windows 字体有、源字体没有的重音字母、标点和符号，
生成时会补进产物，免得这些字回退到别的字体、和正文对不上。能拼的就用源字体自己的字母加
重音符号拼，拼不了才从系统字体里整个搬。补了字的输出会打一行
`[补字] 补 N 个码位，拼 X，搬 Y，组合符号 Z；来源 …`。补哪些、怎么补，看
[`src/patch_glyphs.py`](src/patch_glyphs.py) 的头部注释。

生成完当场就跑 [`src/verify_fonts.py`](src/verify_fonts.py) 自检自己那一份产物，不通过
就非零退出。想不重新生成、只把现有产物再查一遍：

```bash
python src\verify_fonts.py
```

### 3. 预演、安装、回退

预演 —— 打印全部改动，什么都不动：

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\main.ps1 -install -DryRun
```

安装，要在**管理员** PowerShell 里跑：

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\main.ps1 -install
```

然后**注销后重新登录**，或者重启。`FontSubstitutes` 是 GDI 在会话启动时缓存的，光重启
字体缓存服务不够。

全部还原，连装进去的字体文件一起删掉：

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\main.ps1 -revert
```

### 参数

| 参数 | 作用 |
| --- | --- |
| `-install` | 一键全装（机制 1 到 4）。 |
| `-revert` | 按 `winmodernsc-backup.json` 全部还原，并删掉装进去的字体文件。 |
| `-no-fonts` | 跳过机制 1。**等于什么都没换** —— 2 和 3 照样把请求引向 `Segoe UI`，但那还是微软原版 —— 所以只有在之前已经装过一次、这次只想重打注册表时才用得上。 |
| `-no-font-substitutes` | 跳过机制 2。请求 `Tahoma` / `MS Shell Dlg` / `MS Sans Serif` 的老式 Win32 程序保持原来的字体，其它几层不受影响。 |
| `-no-window-metrics` | 跳过机制 3。标题栏、菜单、对话框、状态栏的字体**和字号**都不变，因为这些控件根本不读机制 1 改的 `Fonts` 键。 |
| `-no-font-link` | 跳过机制 4。如果机制 1 装了，GDI 程序显示中文时会回退到原版微软雅黑，而 DirectWrite 用的是新字体，同一屏上就出现两套中文（要是同时加了 `-no-fonts` 则无所谓）。 |
| `-DryRun` | 只打印将要做的改动，什么都不改。可以和 `-install` 或 `-revert` 组合。 |

4 个 `-no-*` 可以任意组合。`-install` 和 `-revert` 互斥。
不带任何参数跑 `main.ps1` 会把这张表打出来。

### 具体改了哪些地方

| 机制 | 位置 |
| --- | --- |
| 1 | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts`（21 个值），字体文件落在 `C:\Fonts` |
| 2 | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontSubstitutes`（8 个值） |
| 3 | `<每个用户>\Control Panel\Desktop\WindowMetrics`（6 个 LOGFONT + 2 个标量） |
| 4 | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink`（最多 20 个值） |

特意没动的：新宋体（等宽，老程序拿它对齐表格）、楷体 / 仿宋、
SimSun-ExtB/ExtG 生僻字扩展、微軟正黑體。

如果你要改这些 `.ps1` 文件，注意保存成 **UTF-8 with BOM** —— Windows PowerShell 5.1 在
没有 BOM 时会按系统 ANSI 代码页去读 `.ps1`，非 ASCII 字符会变乱码。

## Credits

- [fonttools](https://github.com/fonttools/fonttools) —— 用于处理、生成与校验字体文件的 Python 库。
- [noMeiryoUI](https://github.com/Tatsu-syo/noMeiryoUI) —— `WindowMetrics` 这一层
  （机制 3）的参考。
- [Sarasa Gothic](https://github.com/be5invis/Sarasa-Gothic) —— 推荐使用的源字体。
- Claude Code。

生成出来的字体保留源字体自己的版权和许可 `name` 记录。它们是为本机的系统字体替换而造的，
不是拿来分发的；要分享之前请先看清楚源字体的许可。

以 [Apache License 2.0](LICENSE) 授权。
