# -*- coding: utf-8 -*-
"""One-off generator for skill-catalog.zh-CN.json.

The catalog is a hand-written Chinese overlay: the dashboard's skill browser
shows these one-line intros and groups by these categories, while the original
SKILL.md description stays the fallback. Run this again after editing, and keep
the file itself in the repo (the script is not needed at runtime).
"""
import io
import json
import os

CATS = [
    ("workflow", "敏捷研发流程（BMAD）",
     "BMAD 方法的一整套技能：从想法、需求、规格到实现、评审、复盘。"),
    ("planning", "规划与协作",
     "把想法变成可执行的计划、任务单和项目文稿，并推进它们。"),
    ("code", "代码与架构",
     "写码、改码、评审、调试和架构治理，偏向工程实践。"),
    ("motion", "界面与动效",
     "界面设计、动效实现、原型和组件选型。"),
    ("visual", "视觉与图文",
     "插画、信息图、社交卡片等产出图片的技能。"),
    ("academic", "学术与论文",
     "论文写作、投稿、格式与文献。"),
    ("research", "调研与检索",
     "查一手来源、追近期舆情、检索引用，给判断找依据。"),
    ("writing", "写作与内容",
     "中文文案、去 AI 味、平台适配与发布前检查。"),
    ("dbs", "商业方法论（dontbesilent）",
     "dontbesilent 商业教练技能组：决策、增长、内容与工具箱。"),
    ("automation", "自动化与工具",
     "驱动浏览器、桌面、录屏、下载和网络设备配置。"),
]

# name | category | 中文一句话介绍
ROWS = """
bmad|workflow|BMAD 方法的总路由：分析你的现状和问题，回答 BMAD 疑问或推荐下一个该用的技能。
bmad-advanced-elicitation|workflow|高级引导：用连环追问逼 AI 重新审视并打磨刚产出的内容。
bmad-agent-analyst|workflow|业务分析师：做市场调研、竞品分析和需求挖掘。
bmad-agent-architect|workflow|系统架构师：负责技术方案与架构设计。
bmad-agent-dev|workflow|开发工程师：按用户故事写代码、做实现。
bmad-agent-pm|workflow|产品经理：写需求文档、挖需求、定优先级。
bmad-agent-ux-designer|workflow|用户体验设计师：负责体验方案与交互设计。
bmad-architecture|workflow|把架构决策想清楚并记录下来，避免各自开发的部分互相打架。
bmad-brainstorming|workflow|用多种创意技法主持一场头脑风暴。
bmad-build|workflow|把实现工作变成可运行、经过评审和验证的代码。
bmad-build-auto|workflow|无人值守开发循环的一次迭代，按名字调用即自动跑一轮。
bmad-correct-course|workflow|计划发生重大变动时，评估它对需求、史诗、故事和后续安排的影响。
bmad-create-epics-and-stories|workflow|把需求拆成史诗和用户故事。
bmad-customize|workflow|编写和更新已安装 BMAD 技能的定制覆盖层。
bmad-deep-recon|workflow|用三种方式研究一个议题支撑决策：先给一份研究提示词，再由你决定怎么用。
bmad-forge-idea|workflow|在半成形的想法上做提问式对话，用不同人格做压力测试。
bmad-party-mode|workflow|主持一场智能体之间的群聊讨论，用多视角撞出结论。
bmad-prd|workflow|创建、更新或校验产品需求文档。
bmad-prfaq|workflow|用亚马逊倒推法检验产品概念：先写新闻稿和常见问题，再决定做不做。
bmad-product-brief|workflow|创建、更新或校验产品简报。
bmad-project-context|workflow|建立、采用、刷新或审计仓库的智能体指令块。
bmad-qa-generate-e2e-tests|workflow|为已实现的功能生成接口与端到端自动化测试。
bmad-retrospective|workflow|对照一个史诗留下的证据（规格、故事、改动、提交）做复盘。
bmad-review|workflow|跑一个或多个评审视角：挑刺、找边界情况、验证结论。
bmad-spec|workflow|把任何输入（想法、简报、需求、记录、混杂笔记）压成一份短规格。
bmad-sprint-planning|workflow|检查计划是否完整到可以开工，然后生成迭代状态文件。
bmad-ux|workflow|用两份文档抓住产品的体验方向：一份管长相，一份管落地。
bmad-walkthrough|workflow|带着你过一遍一个改动：它干什么、该重点看什么、怎么判断对不对。
agent-handover|planning|项目交接：把当前状态、隐性知识和配置整理成交接文档，交给下一个助手接着干。
ask-matt|planning|技能路由器：你说清自己的处境，它告诉你该用哪个技能、走哪条流程。
grilling|planning|就一个计划、决定或想法对你连环追问，直到它站得住。
loop-me|planning|在这个工作区里，就你想做的工作流规格连环追问。
retro|planning|给一次编程会话做复盘：哪里顺、哪里卡、下次怎么改。
scaffold-exercises|planning|生成带讲解、习题、答案的练习目录结构，适合教学。
teach|planning|在这个工作区里教你一个新技能或概念。
to-questionnaire|planning|把你答不完整的问题整理成一份问卷，交给别人去填。
to-spec|planning|把当前对话整理成规格，发布到项目的问题跟踪面板。
to-tickets|planning|把计划、规格或当前对话拆成一批能跑起来的小任务单。
triage|planning|让问题和外部 PR 走一套状态机：分类、分级、验证、推进。
wayfinder|planning|把一个人干不完的大工程画成一张共享地图：决策、依赖、顺序。
wizard|planning|生成一个交互式命令行向导，带着人一步步做只有人能做的事。
codebase-design|code|深模块设计的共同词汇，用来讨论和改进模块边界。
code-review-mattpocock|code|从某个固定点开始的改动，沿写得对不对和设计好不好两条轴评审。
diagnosing-bugs|code|难 bug 与性能回归的诊断循环：系统地逼近根因。
dogfood|code|自己产品的探索性测试：找 bug、留证据、出报告。
domain-modeling|code|建立并打磨项目的领域模型，统一术语和代码里的概念。
git-guardrails-claude-code|code|给 Claude Code 装钩子，拦住 push、reset --hard、clean 等危险操作。
improve-codebase-architecture|code|扫一遍代码库找可以挖深的地方，出可视化报告，再逐步改。
karpathy-guidelines|code|减少大模型写代码常见毛病的行为准则。
migrate-to-shoehorn|code|把测试里的旧式断言迁移到 shoehorn 类型断言。
resolving-merge-conflicts|code|解决进行中的合并或变基冲突。
setup-matt-pocock-skills|code|给仓库配好工程类技能：问题面板、标签词表等前置设置。
setup-pre-commit|code|装提交前钩子：格式检查、类型检查、跑测试。
setup-ts-deep-modules|code|给 TypeScript 仓库接入依赖检查，让每个包都守住自己的边界。
tdd|code|测试驱动开发：先写测试，再写功能、修 bug。
animate|motion|从零做一个动画：先决定该不该动、为什么动，再选工具、属性、曲线和时长，并写出实现。
animation-vocabulary|motion|动效术语反查词典：把弹一下、苹果那种回弹这类模糊描述换成准确术语。
apple-design|motion|苹果式的界面与物理动效设计方法落地到 Web：手势、弹簧、可中断过渡、材质与排版。
ask-sonner|motion|React 提示条库的使用指南：安装、接入、类型、位置与动画。
emil-design-eng|motion|Emil Kowalski 的界面设计哲学：组件细节、动画品味与打磨标准。
find-animation-opportunities|motion|在界面或代码里找出该动但没动的地方，并砍掉不该动的。
impeccable|motion|界面打磨的集大成者：设计、改版、定型、评审、审计、抛光一次做完。
improve-animations|motion|以资深动效顾问的眼光扫一遍动效代码，先给计划再动手。
liquid-glass|motion|实现液态玻璃效果：毛玻璃、折射、高光与分层。
pick-ui-library|motion|前端选型参考：数字滚动、颜色、动画、图表等场景各该用哪个库。
prototype|motion|把你描述的一块界面做出多个真正不同的版本，并排摆着看。
prototype-mattpocock|motion|做一个一次性原型，专门回答一个设计问题。
react-bits|motion|动画界面组件库：文字特效、光标特效、画布背景等即插即用组件。
review-animations|motion|按很高的手艺标准评审动效代码。
ui-ux-pro-max|motion|界面设计知识库：多种风格与行业规范，可本地检索。
guizang-social-card-skill|visual|贵藏风格社交卡片配图、动态卡片与公众号封面图。
ian-xiaohei-illustrations|visual|伊恩小黑插画：四宫格、大纲页、宽图、头像等统一风格配图。
infographic-maker|visual|把文章、概念、报告或数据做成手绘卡通风格的信息图。
bib-search-citation|research|在本地文献库（含文献管理软件导出）里检索并生成引用。
cover-letter|academic|给已有稿件写投稿信并优化。
latex-paper-en|academic|英文论文排版助手：编译修复、格式与投稿要求。
latex-thesis-zh|academic|中文学位论文排版：结构、国标参考文献、格式与编译。
paper-audit|academic|审稿人视角的论文审计与投稿把关：先挑刺，再决定投不投。
paper-download-proxy|academic|中文学术库的批量下载流程，省去重复撞墙。
research|research|针对一个疑问查高可信的一手来源，把发现整理成文档。
last30days|research|查一个话题最近 30 天网上大家真实在说什么：抓帖子、评论和情绪。
typst-paper|academic|Typst 论文助手：中英文稿件的编译与格式。
anti-ai-detector|writing|去 AI 味终稿防御：针对主流检测工具定向消除特征，把 AI 概率压下来。
content-research-writer|writing|边研究边写高质量内容：查资料、加引用、改表达。
human-writing|writing|通读你的稿子，把 AI 腔、套话、空洞表达改成像人写的。
qu-ai-wei|writing|去 AI 味：找回真人书写的真实感，删掉模板句和空话。
writing-for-agents|writing|写给智能体看的文档：技能和指令文件怎么写才起作用。
writing-fragments|writing|写作·探索：把零碎原始素材先攒起来，不管结构。
writing-shape|writing|写作·开采：把原始素材一段段打磨成文章。
x-yuwen-style|writing|仿特定公众号的文案风格，写出他那种感觉的文字。
yuanbao|writing|元宝社群运营：@人、查信息、管成员。
yuwen-publish-precheck|writing|文案发布前检查：改病句、查敏感词、过平台规范。
dbs|dbs|dontbesilent 技能组的总入口。
dbs-action|dbs|学完就用：把学到的东西落成一个具体动作，专治知道很多但没动。
dbs-agent-migration|dbs|识别项目里的旧指令来源，统一迁移到新的智能体配置体系。
dbs-ai-check|dbs|扫描标书与文档里的 AI 写作文本和逻辑漏洞，找出该人工复核的段落。
dbs-benchmark|dbs|反向拆解一个值得学的对标：它火在哪、抄什么、不抄什么。
dbs-bridge|dbs|把 dontbesilent 的技能桥接到各家智能体工具。
dbs-chatroom|dbs|多模型群聊：让几个 AI 围着一个话题开一场讨论会。
dbs-chatroom-austrian|dbs|奥地利经济学派圆桌：让米塞斯、哈耶克、熊彼特替你剖析商业现象。
dbs-content|dbs|选题与会话沉淀：把聊过的东西整理成可复用的内容资产。
dbs-content-system|dbs|把选题、素材、成文、发布串成一条内容流水线，形成可复用系统。
dbs-decision|dbs|在职业、创业、关系、投资等两难时刻，用一套框架把决定想清楚。
dbs-deconstruct|dbs|用第一性原理重解一个商业现象：拆到基本要素，再重新组合。
dbs-diagnosis|dbs|用一套诊断模式判断业务卡在哪：获客、转化、复购还是产品。
dbs-goal|dbs|只追真正影响结果的少数目标，帮你砍掉伪目标。
dbs-good-question|dbs|教你写出能撬动 AI 的高质量提问，并判断它答得好不好。
dbs-hook|dbs|短视频黄金三秒与钩子写法，专治开头留不住人。
dbs-learning|dbs|一个主题的系统学习包：书单、路径与学习顺序。
dbs-report|dbs|把会话沉淀合并成一份可交付的报告。
dbs-resonate|dbs|找出你和用户之间真正的共鸣点，写出这就是在说我的表达。
dbs-restore|dbs|恢复上次保存的会话状态：聊到哪、结论是什么。
dbs-save|dbs|把当前会话的关键状态存成快照，下次接着聊。
dbs-script-flow|dbs|短视频与口播的流程设计：顺序、信息密度和钩子怎么排。
dbs-slowisfast|dbs|识别关键事务里的假忙碌：哪些勤奋其实在拖慢重要的事。
dbs-spread|dbs|五步裂变法：让内容自己传播出去，而不是一条条硬推。
dbs-update|dbs|更新 dontbesilent 技能包。
dbs-wechat-html|dbs|把 Markdown 转成适配公众号图文的网页代码，内置多套样式。
dbs-xhs-title|dbs|从一批验证过的爆款公式里挑合适的小红书标题写法。
the-entrepreneurship-handbook|dbs|创业者与管理者的问答手册：遇到事先来问。
beike-assistant|automation|找房业务助手：回答房价、小区、房源、首付贷款等相关问题。
browseros-neo|automation|智能体专用浏览器：一个已登录你各账号的真浏览器，可以放心去点。
computer-use|automation|在后台驱动你的桌面：点击、输入、滚动、拖拽。
ensp-topo-generate|automation|把网络拓扑生成成可直接打开仿真的工程文件。
grbj-ensp-smart-config|automation|网络设备智能配置：改配置、查原因、给验证用的操作手册。
obs-recording|automation|调优录屏软件：改配置文件，切换编码器等。
parallel-large-download|automation|大文件（镜像、数据集、压缩包）分段并行下载。
"""


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out_path = os.path.join(os.path.dirname(here), "skill-catalog.zh-CN.json")

    valid = {cid for cid, _, _ in CATS}
    skills = {}
    for lineno, line in enumerate(ROWS.strip().splitlines(), start=1):
        parts = line.split("|", 2)
        if len(parts) != 3:
            raise SystemExit("line %d: expected name|cat|desc, got %r" % (lineno, line))
        name, cat, desc = (p.strip() for p in parts)
        if cat not in valid:
            raise SystemExit("line %d: unknown category %r" % (lineno, cat))
        if name in skills:
            raise SystemExit("line %d: duplicate skill %r" % (lineno, name))
        if not desc:
            raise SystemExit("line %d: empty description for %r" % (lineno, name))
        skills[name] = {"cat": cat, "desc": desc}

    payload = {
        "note": (
            "SkillBridge 自带的中文分类与简介，只用于仪表盘的技能库展示。"
            "每个技能的原始描述仍读各自的 SKILL.md；这里没有的条目按原文显示，"
            "分类归到其他。新增技能时在这里补一行即可。"
        ),
        "categories": [{"id": cid, "name": name, "desc": desc} for cid, name, desc in CATS],
        "skills": {name: skills[name] for name in sorted(skills)},
    }
    with io.open(out_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(payload, f, ensure_ascii=False, indent=1)
        f.write("\n")

    counts = {}
    for entry in skills.values():
        counts[entry["cat"]] = counts.get(entry["cat"], 0) + 1
    print("wrote %s: %d skills, %d categories" % (out_path, len(skills), len(CATS)))
    for cid, name, _ in CATS:
        print("  %-10s %-22s %d" % (cid, name, counts.get(cid, 0)))


if __name__ == "__main__":
    main()
