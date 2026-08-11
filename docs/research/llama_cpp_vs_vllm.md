# Research Report: llama.cpp (llama-server) vs. vLLM for AI Platform Inference Nodes

## Executive Summary

Both **llama.cpp** (`llama-server`) and **vLLM** expose OpenAI-compatible HTTP endpoints (`/v1/chat/completions`), making them drop-in compatible with **LiteLLM**. The choice depends on hardware constraints and model formats:

- **Use `llama.cpp`** if the inference PC has consumer GPUs with limited VRAM (e.g. 8GB - 24GB) and you want low-memory GGUF quantized models with a single binary deployment.
- **Use `vLLM`** if the inference PC has high-end NVIDIA GPUs, requires maximum token throughput, continuous batching (PagedAttention), and natively runs SafeTensors / HuggingFace models.

---

## Detailed Comparison Matrix

| Axis | `llama.cpp` (`llama-server`) | `vLLM` |
|---|---|---|
| **Model Weight Format** | **GGUF** (K-quants: Q4_K_M, Q8_0, etc.) | **SafeTensors / PyTorch** (FP16, BF16, AWQ, GPTQ, FP8) |
| **Memory Efficiency** | High VRAM efficiency via GGUF quantization | High throughput via **PagedAttention** KV cache allocation |
| **Deployment Complexity** | Low (Single C++ binary) | Medium (Python venv + PyTorch + CUDA Toolkit) |
| **OpenAI API Support** | `/v1/chat/completions`, `/v1/models`, `/v1/embeddings` | Full `/v1/chat/completions`, `/v1/models`, Tool Calling, Vision |
| **Health Checks** | `GET /health` or `GET /v1/models` | `GET /health` or `GET /v1/models` |
| **Multi-GPU Scaling** | Split-layer distribution | Native Tensor & Pipeline Parallelism |

---

## Recommendation for AI Platform

For **v1**, we recommend support for **both** via LiteLLM's standard OpenAI adapter:

1. **Default Recommendation for Consumer GPUs**: **llama.cpp** (`llama-server`) running quantized GGUF models (e.g., `qwen2.5-coder-7b-instruct.Q4_K_M.gguf`).
2. **For High-Throughput / Multi-GPU Hardware**: **vLLM** (`vllm serve`) for unquantized or AWQ SafeTensors models.
