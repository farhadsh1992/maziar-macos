import { callOpenAICompatible } from '../services/llmService.js';

export function registerLLMRoutes(fastify) {
  fastify.post('/api/llm', async (req) => {
    const { messages, model, llmConfig } = req.body || {};
    const result = await callOpenAICompatible({
      messages,
      model: llmConfig?.model || model,
      endpoint: llmConfig?.endpoint,
      apiKey: llmConfig?.apiKey
    });
    return result;
  });
}
