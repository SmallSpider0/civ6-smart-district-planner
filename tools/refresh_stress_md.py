"""Put the late-game stress table (report/build.py --stress-md) into
docs/self-test-report.md, between its heading and the paragraph after it.

    python3 -I tools/refresh_stress_md.py
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC = os.path.join(ROOT, "docs", "self-test-report.md")
HEAD = "**后期存档压力测试**"
NEXT = "这轮压力测试找到并修好的"


def main():
    md = subprocess.run([sys.executable, "-I", os.path.join(ROOT, "report", "build.py"), "--stress-md"],
                        capture_output=True, text=True, check=True).stdout.strip()
    with open(DOC, encoding="utf-8") as fh:
        text = fh.read()
    start = text.index(HEAD)
    body = text.index("\n\n", start) + 2
    end = text.index(NEXT, body)
    text = text[:body] + md + "\n\n" + text[end:]
    with open(DOC, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("stress table refreshed in docs/self-test-report.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
