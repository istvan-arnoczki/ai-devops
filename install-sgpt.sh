pip install shell-gpt --break-system-packages
export OPENAI_API_BASE=http://localhost:11434/v1
export OPENAI_API_KEY=ollama
export PATH=$PATH:~/.local/bin
sgpt --model qwen2.5-coder:14b "explain GCP routable VPC networks"
