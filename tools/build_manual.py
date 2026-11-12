#!/usr/bin/env python3
"""把分刻产品手册.md 生成网页版 HTML（内联样式 + base64 截图）。

用法：python3 tools/build_manual.py
产物：分刻产品手册.html（单文件，可直接分发）
"""
import base64
import os
import re

import markdown

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 2.7 改名：手册也跟着换名，旧名保留回退，历史分支仍能构建
SRC_MD = os.path.join(ROOT, "分刻产品手册.md")
if not os.path.exists(SRC_MD):
    SRC_MD = os.path.join(ROOT, "小薪薪产品手册.md")
OUT_HTML = os.path.join(ROOT, "分刻产品手册.html")
TPL_HTML = os.path.join(ROOT, "manual-assets", "template.html")

EXTRA_CSS = """
img{max-width:100%; height:auto; display:block; margin:22px auto 8px;
    border:1px solid var(--line); border-radius:12px;
    box-shadow:0 10px 30px rgba(20,30,50,.10);}
p > img + em, p > em:only-child{display:block; text-align:center; font-size:12.5px; color:var(--ink-3);}
hr{border:0; height:1px; background:var(--line); margin:44px 0;}
/* 打印：截图去掉边框与阴影，避免 PDF 里出现灰色底板；同时压一下高度免得撑爆版心 */
@media print{
  img{box-shadow:none; border:0; max-width:76%; max-height:150mm; width:auto; height:auto;}
}
"""


def read_head():
    """沿用历史版本的 <head>（含全部样式），保证视觉不变。"""
    if os.path.exists(TPL_HTML):
        head = open(TPL_HTML, encoding="utf-8").read()
    else:
        html = open(OUT_HTML, encoding="utf-8").read()
        head = html[: html.index("</head>") + 7]
    return head.replace("</style>", EXTRA_CSS + "</style>")


def embed_images(html):
    def repl(m):
        path = m.group(1)
        abs_path = os.path.join(ROOT, path)
        if not os.path.exists(abs_path):
            print(f"!! 缺图: {path}")
            return m.group(0)
        data = base64.b64encode(open(abs_path, "rb").read()).decode()
        ext = "jpeg" if path.lower().endswith((".jpg", ".jpeg")) else "png"
        return f'src="data:image/{ext};base64,{data}"'

    return re.sub(r'src="([^"]+)"', repl, html)


def main():
    md_text = open(SRC_MD, encoding="utf-8").read()
    body = markdown.markdown(
        md_text,
        extensions=["tables", "fenced_code", "sane_lists", "nl2br"],
        output_format="html5",
    )
    body = embed_images(body)
    html = read_head() + f"\n<body>\n<div class=\"wrap\">\n{body}\n</div>\n</body>\n</html>\n"
    open(OUT_HTML, "w", encoding="utf-8").write(html)
    print(f"已生成 {OUT_HTML}  ({os.path.getsize(OUT_HTML)/1048576:.2f} MB)")

    # 出图前的数值校验：对外材料统一 3500 档
    text = re.sub(r"<[^>]+>", " ", body)
    for token in ["¥3,500", "¥0.0058", "¥166.67"]:
        print(("  ✓ " if token in text else "  ✗ 缺少 ") + token)
    for bad in ["20,000", "0.0331", "952.38", "v1.3"]:
        if bad in text:
            print(f"  !! 残留旧数据: {bad}")


if __name__ == "__main__":
    main()
