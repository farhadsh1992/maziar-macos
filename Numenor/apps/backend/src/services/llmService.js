import { ChatOpenAI } from '@langchain/openai';
import { providerCompletion } from './ai/providers.js';

export async function callOpenAICompatible({ messages }) {
  try {
    const result = await providerCompletion({ messages, temperature: 0.2 });
    const content = result.choices?.[0]?.message?.content;
    return typeof content === 'string'
      ? { ok: true, content }
      : { ok: false, error: 'The selected provider did not return text.' };
  } catch (error) {
    return { ok: false, error: error.message };
  }
}

// Preserve the existing LangChain tools and transfer workflows through the active provider.
export function activeChatModel() {
  return new ChatOpenAI({
    model: 'active-provider',
    apiKey: 'local-adapter',
    maxRetries: 0,
    temperature: 0.2,
    configuration: {
      baseURL: 'http://numenor.invalid/v1',
      fetch: async (_url, options) => {
        try {
          const body = JSON.parse(options.body);
          const response = await providerCompletion(body, options.signal);
          return Response.json({ id: 'numenor', model: 'active-provider', object: 'chat.completion', ...response });
        } catch (error) {
          return Response.json({ error: { message: error.message } }, { status: 400 });
        }
      }
    }
  });
}
