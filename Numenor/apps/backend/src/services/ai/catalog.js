function qwen(id, name, repo, revision, filename, bytes, sha256, role) {
  return {
    id, name, bytes, sha256, role, quantization: 'GGUF Q4_K_M (4-bit)',
    url: `https://huggingface.co/unsloth/${repo}/resolve/${revision}/${filename}`,
    license: 'https://www.apache.org/licenses/LICENSE-2.0'
  };
}

export const catalog = [
  qwen('qwen3-0.6b', 'Qwen3 0.6B', 'Qwen3-0.6B-GGUF', '50968a4468ef4233ed78cd7c3de230dd1d61a56b',
    'Qwen3-0.6B-Q4_K_M.gguf', 396705472, 'ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a',
    'Smallest option for simple text actions'),
  qwen('qwen3-1.7b', 'Qwen3 1.7B', 'Qwen3-1.7B-GGUF', 'd7f544eead698dbd1f15126ef60b45a1e1933222',
    'Qwen3-1.7B-Q4_K_M.gguf', 1107409472, 'b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897',
    'Starting point for an 8 GB Mac'),
  qwen('qwen3-4b-instruct', 'Qwen3 4B Instruct', 'Qwen3-4B-Instruct-2507-GGUF', 'a06e946bb6b655725eafa393f4a9745d460374c9',
    'Qwen3-4B-Instruct-2507-Q4_K_M.gguf', 2497281120, '3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597',
    'Larger option for writing and diagnostics')
];

export const runtimeArtifact = {
  url: 'https://github.com/ggml-org/llama.cpp/releases/download/b6500/llama-b6500-bin-macos-arm64.zip',
  bytes: 10699243,
  sha256: '4f34ae19823ee22e8036d6da91f083ca62ab926c2a0a4a5ce9df34897360087b'
};
