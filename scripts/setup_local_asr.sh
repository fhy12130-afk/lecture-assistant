#!/bin/bash
# 安装本地第二识别引擎（sherpa-onnx + SenseVoice + Paraformer，约 500 MB）
# 装到 ~/Library/Application Support/LectureAssistant/，应用启动时会自动拉起。
set -euo pipefail
cd "$(dirname "$0")"
DIR="$HOME/Library/Application Support/LectureAssistant"
mkdir -p "$DIR/models/dl"

if ! command -v uv >/dev/null 2>&1; then
  echo "需要 uv：https://docs.astral.sh/uv/  （或改成你自己的 python3.11 venv）"; exit 1
fi
[ -x "$DIR/asr-venv/bin/python" ] || uv venv --python 3.11 "$DIR/asr-venv"
uv pip install --python "$DIR/asr-venv/bin/python" sherpa-onnx numpy

BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"
for name in sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09 sherpa-onnx-paraformer-zh-2023-09-14; do
  if [ -d "$DIR/models/$name" ]; then echo "已有 $name"; continue; fi
  # 多连接分段下载，国内网络下比单连接快很多
  python3 download.py "$BASE/$name.tar.bz2" "$DIR/models/dl/$name.tar.bz2" 10
  tar -xjf "$DIR/models/dl/$name.tar.bz2" -C "$DIR/models"
  rm -f "$DIR/models/dl/$name.tar.bz2"
done
cp asr_server.py "$DIR/asr_server.py"
echo "装好了。重开讲座助手，状态栏会显示「+ paraformer/sensevoice」。"
