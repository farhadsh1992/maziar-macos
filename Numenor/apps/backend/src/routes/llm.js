import { callOpenAICompatible } from '../services/llmService.js';

export function registerLLMRoutes(fastify) {
  fastify.post('/api/llm', async (req) => callOpenAICompatible({ messages: req.body?.messages }));
}
